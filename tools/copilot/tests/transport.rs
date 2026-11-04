use serde_json::{Value, json};
use std::{
    io::{BufRead, BufReader, Write},
    path::PathBuf,
    process::{Child, ChildStdin, Command, Stdio},
    sync::mpsc::{self, Receiver},
    time::{Duration, SystemTime, UNIX_EPOCH},
};

struct Helper {
    child: Child,
    stdin: ChildStdin,
    output: Receiver<Value>,
    dir: PathBuf,
}

impl Helper {
    fn new(disable_mcp: bool) -> Self {
        let dir = std::env::temp_dir().join(format!(
            "neostar-sdk-test-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir(&dir).unwrap();
        let manifest = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
        let mut command = Command::new(env!("CARGO_BIN_EXE_neostar-copilot"));
        command
            .args(["--cli"])
            .arg(manifest.join("tests/fake_runtime.py"))
            .arg("--cwd")
            .arg(&manifest)
            .arg("--state-dir")
            .arg(&dir)
            .env("NEOSTAR_SDK_TEST_LOG", dir.join("runtime.jsonl"))
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit());
        if disable_mcp {
            command.env("NEOSTAR_SDK_TEST_DISABLE_MCP", "1");
        }
        let mut child = command.spawn().unwrap();
        let stdin = child.stdin.take().unwrap();
        let stdout = child.stdout.take().unwrap();
        let (send, output) = mpsc::channel();
        std::thread::spawn(move || {
            for line in BufReader::new(stdout).lines() {
                if send
                    .send(serde_json::from_str(&line.unwrap()).unwrap())
                    .is_err()
                {
                    break;
                }
            }
        });
        let helper = Self {
            child,
            stdin,
            output,
            dir,
        };
        assert_eq!(helper.next()["type"], "ready");
        helper
    }

    fn next(&self) -> Value {
        self.output
            .recv_timeout(Duration::from_secs(10))
            .expect("helper event")
    }

    fn send(&mut self, message: Value) {
        writeln!(self.stdin, "{message}").unwrap();
        self.stdin.flush().unwrap();
    }

    fn run(&mut self, id: u64, token: &str, resume: Option<&str>, prompt: &str) {
        self.send(json!({
            "op": "run", "id": id, "prompt": prompt, "system_prompt": "read only",
            "keep_session": true,
            "resume": resume, "mcp_server": {"type": "http",
                "url": "http://127.0.0.1:1/mcp", "headers": {"Authorization": token}},
        }));
    }

    fn done(&self) -> Vec<Value> {
        let mut messages = vec![];
        loop {
            let message = self.next();
            let done = message["type"] == "done";
            messages.push(message);
            if done {
                return messages;
            }
        }
    }

    fn log(&self) -> Vec<Value> {
        std::fs::read_to_string(self.dir.join("runtime.jsonl"))
            .unwrap()
            .lines()
            .map(|line| serde_json::from_str(line).unwrap())
            .collect()
    }
}

impl Drop for Helper {
    fn drop(&mut self) {
        let _ = writeln!(self.stdin, "{{\"op\":\"shutdown\"}}");
        let deadline = std::time::Instant::now() + Duration::from_secs(3);
        while self.child.try_wait().ok().flatten().is_none() {
            if std::time::Instant::now() > deadline {
                let _ = self.child.kill();
                let _ = self.child.wait();
                break;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

#[test]
fn resumes_with_rotated_mcp_credentials_in_one_runtime() {
    let mut helper = Helper::new(false);
    helper.run(1, "first-token", None, "explain");
    let first = helper.done();
    assert_eq!(
        first.last().unwrap()["ok"],
        true,
        "{first:?}; RPC: {:?}",
        helper.log()
    );
    let session = first[0]["session_id"].as_str().unwrap();
    helper.run(2, "second-token", Some(session), "follow up");
    let second = helper.done();
    assert_eq!(second.last().unwrap()["ok"], true);
    assert!(
        second
            .iter()
            .any(|message| message["event"]["data"]["deltaContent"] == "second-token")
    );
    let log = helper.log();
    assert_eq!(
        log.iter()
            .filter(|message| message["method"] == "connect")
            .count(),
        1
    );
    let resume = log
        .iter()
        .find(|message| message["method"] == "session.mcp.restartServer")
        .unwrap();
    assert_eq!(
        resume["params"]["config"]["headers"]["Authorization"],
        "second-token"
    );
    assert!(
        !log.iter()
            .any(|message| message["method"] == "session.detach")
    );
    helper.send(json!({"op": "release", "session_id": session}));
    helper.run(3, "third-token", None, "explain");
    assert_eq!(helper.done().last().unwrap()["ok"], true);
    assert!(
        helper
            .log()
            .iter()
            .any(|message| message["method"] == "session.detach")
    );
}

#[test]
fn cancels_a_turn_and_can_start_another_without_restarting() {
    let mut helper = Helper::new(false);
    helper.run(1, "first-token", None, "wait");
    loop {
        let message = helper.next();
        assert_ne!(
            message["type"],
            "done",
            "{message}; RPC: {:?}",
            helper.log()
        );
        if message["type"] == "event" {
            break;
        }
    }
    helper.send(json!({"op": "cancel", "id": 1}));
    let canceled = helper.done();
    assert_eq!(canceled.last().unwrap()["error"], "stopped");
    helper.run(2, "second-token", None, "explain");
    assert_eq!(helper.done().last().unwrap()["ok"], true);
    assert!(
        helper
            .log()
            .iter()
            .any(|message| message["method"] == "session.abort")
    );
}

#[test]
fn fails_before_inference_when_mcp_is_disabled() {
    let mut helper = Helper::new(true);
    helper.run(1, "token", None, "must not send");
    let messages = helper.done();
    let result = messages.last().unwrap();
    assert_eq!(result["ok"], false);
    assert!(
        result["error"].as_str().unwrap().contains("MCP"),
        "{result}; RPC: {:?}",
        helper.log()
    );
    assert!(
        !helper
            .log()
            .iter()
            .any(|message| message["method"] == "session.send")
    );
}
