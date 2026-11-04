use github_copilot_sdk::{
    CliProgram, Client, ClientOptions, McpServerConfig, PermissionRequestData,
    PermissionRequestKind, ResumeSessionConfig, SessionConfig, SystemMessageConfig,
    mode::ClientMode, permission::approve_if, session::Session,
};
use serde::Deserialize;
use serde_json::{Value, json};
use std::{collections::HashMap, path::PathBuf, sync::Arc, time::Duration};
use tokio::{
    io::{AsyncBufReadExt, AsyncWriteExt, BufReader},
    sync::{Mutex, mpsc, watch},
    task::JoinSet,
    time::{sleep, timeout},
};

const MCP_TOOLS: &[&str] = &[
    "neostar_context",
    "fstar_lookup",
    "fstar_compute",
    "fstar_diagnostics",
    "check_proof",
    "propose_proof",
];

#[derive(Debug, Deserialize)]
struct Turn {
    prompt: String,
    system_prompt: String,
    model: Option<String>,
    resume: Option<String>,
    mcp_server: McpServerConfig,
    #[serde(default)]
    keep_session: bool,
}

#[derive(Debug, Deserialize)]
#[serde(tag = "op", rename_all = "snake_case")]
enum Request {
    Run {
        id: u64,
        #[serde(flatten)]
        turn: Box<Turn>,
    },
    Cancel {
        id: u64,
    },
    Release {
        session_id: String,
    },
    Shutdown,
}

fn permitted(root: &std::path::Path, request: &PermissionRequestData) -> bool {
    if request.managed_approval_required == Some(true) {
        return false;
    }
    let data = request
        .extra
        .get("permissionRequest")
        .unwrap_or(&request.extra);
    if data["managedApprovalRequired"] == true {
        return false;
    }
    let kind = request
        .kind
        .or_else(|| serde_json::from_value(data["kind"].clone()).ok());
    match kind {
        Some(PermissionRequestKind::Read) => {
            if data["requestSandboxBypass"] == true {
                return false;
            }
            data["resolvedPath"]
                .as_str()
                .or_else(|| data["path"].as_str())
                .and_then(|path| root.join(path).canonicalize().ok())
                .is_some_and(|path| path.starts_with(root))
        }
        Some(PermissionRequestKind::Mcp) => {
            data["serverName"] == "neostar"
                && data["toolName"]
                    .as_str()
                    .is_some_and(|name| MCP_TOOLS.contains(&name))
        }
        _ => false,
    }
}

fn tool_filter() -> Vec<String> {
    ["view", "glob", "rg"]
        .iter()
        .map(|name| format!("builtin:{name}"))
        .chain(MCP_TOOLS.iter().map(|name| format!("mcp:neostar-{name}")))
        .collect()
}

type Sessions = Arc<Mutex<HashMap<String, Arc<Session>>>>;

async fn open_session(
    client: &Client,
    sessions: &Sessions,
    root: PathBuf,
    turn: &Turn,
) -> Result<Arc<Session>, String> {
    if let Some(id) = &turn.resume {
        let session = sessions.lock().await.get(id).cloned();
        if let Some(session) = session {
            session
                .rpc()
                .mcp()
                .restart_server(
                    serde_json::from_value(
                        json!({"serverName": "neostar", "config": turn.mcp_server}),
                    )
                    .map_err(|error| error.to_string())?,
                )
                .await
                .map_err(|error| format!("Cannot refresh Copilot MCP credentials: {error}"))?;
            return Ok(session);
        }
    }
    let permission_root = root.clone();
    let handler = approve_if(move |request| permitted(&permission_root, request));
    let servers = [("neostar".to_owned(), turn.mcp_server.clone())]
        .into_iter()
        .collect();
    let system = SystemMessageConfig::new()
        .with_mode("append")
        .with_content(&turn.system_prompt);
    let result = if let Some(id) = &turn.resume {
        let mut config = ResumeSessionConfig::new(id.as_str().into())
            .with_streaming(true)
            .with_system_message(system)
            .with_working_directory(root)
            .with_skip_custom_instructions(false)
            .with_available_tools(tool_filter())
            .with_mcp_servers(servers)
            .with_permission_handler(handler);
        config.model = turn.model.clone();
        config.enable_config_discovery = Some(false);
        config.enable_on_demand_instruction_discovery = Some(true);
        config.enable_session_store = Some(true);
        client.resume_session(config).await
    } else {
        let mut config = SessionConfig::default()
            .with_streaming(true)
            .with_system_message(system)
            .with_working_directory(root)
            .with_skip_custom_instructions(false)
            .with_available_tools(tool_filter())
            .with_mcp_servers(servers)
            .with_permission_handler(handler);
        config.model = turn.model.clone();
        config.enable_config_discovery = Some(false);
        config.enable_on_demand_instruction_discovery = Some(true);
        config.enable_session_store = Some(true);
        config.client_name = Some("neostar".to_owned());
        client.create_session(config).await
    };
    let session = Arc::new(result.map_err(|error| format!("Copilot session: {error}"))?);
    if turn.keep_session {
        sessions
            .lock()
            .await
            .insert(session.id().to_string(), session.clone());
    }
    Ok(session)
}

async fn check_mcp(session: &Session) -> Result<(), String> {
    for _ in 0..100 {
        let list = session.rpc().mcp().list().await.map_err(|error| {
            format!("Cannot inspect Copilot MCP connections (check CLI/SDK compatibility): {error}")
        })?;
        if let Some(server) = list.servers.iter().find(|server| server.name == "neostar") {
            match serde_json::to_value(&server.status)
                .unwrap_or_default()
                .as_str()
            {
                Some("connected") => return Ok(()),
                Some("pending") => {}
                _ => {
                    return Err(format!(
                        "Copilot cannot connect to neostar's MCP tools: {}",
                        server
                            .error
                            .as_deref()
                            .unwrap_or("MCP may be disabled by organization policy")
                    ));
                }
            }
        }
        sleep(Duration::from_millis(100)).await;
    }
    Err("Timed out connecting Copilot to neostar's MCP tools".into())
}

async fn run_turn(
    client: Arc<Client>,
    root: PathBuf,
    id: u64,
    turn: Turn,
    mut cancel: watch::Receiver<bool>,
    output: mpsc::UnboundedSender<Value>,
    sessions: Sessions,
) -> Result<(), String> {
    let session = timeout(
        Duration::from_secs(30),
        open_session(&client, &sessions, root, &turn),
    )
    .await
    .map_err(|_| "Timed out opening a Copilot session".to_owned())??;
    let _ = output.send(json!({"type": "session", "id": id, "session_id": session.id()}));
    let mut events = session.subscribe();
    let conversation = async {
        timeout(Duration::from_secs(15), check_mcp(&session))
            .await
            .map_err(|_| "Timed out connecting Copilot to neostar's MCP tools".to_owned())??;
        session
            .send(turn.prompt)
            .await
            .map_err(|error| error.to_string())?;
        loop {
            let event = events
                .recv()
                .await
                .map_err(|error| format!("Copilot event stream interrupted: {error}"))?;
            if event.event_type == "session.idle" {
                return Ok(());
            }
            if event.event_type == "session.error" && !event.is_transient_error() {
                return Err(event.data["message"]
                    .as_str()
                    .unwrap_or("Copilot session error")
                    .to_owned());
            }
            let _ = output.send(json!({"type": "event", "id": id, "event": event}));
        }
    };
    let result = if *cancel.borrow() {
        Err("stopped".to_owned())
    } else {
        tokio::select! {
            result = conversation => result,
            _ = cancel.changed() => Err("stopped".to_owned()),
        }
    };
    let keep = turn.keep_session && result.is_ok();
    if result.is_err() {
        let _ = timeout(Duration::from_secs(5), session.abort()).await;
    }
    if !keep
        || !sessions
            .lock()
            .await
            .contains_key(&session.id().to_string())
    {
        sessions.lock().await.remove(&session.id().to_string());
        let disconnected = timeout(Duration::from_secs(5), session.disconnect()).await;
        if result.is_ok() {
            disconnected
                .map_err(|_| "Timed out disconnecting Copilot session".to_owned())?
                .map_err(|error| format!("Copilot disconnect: {error}"))?;
        }
    }
    result
}

async fn terminated() {
    #[cfg(unix)]
    {
        let mut term = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
            .expect("install SIGTERM handler");
        tokio::select! { _ = term.recv() => {}, _ = tokio::signal::ctrl_c() => {} }
    }
    #[cfg(not(unix))]
    let _ = tokio::signal::ctrl_c().await;
}

async fn serve(client: Arc<Client>, root: PathBuf) -> Result<(), String> {
    let (output, mut outgoing) = mpsc::unbounded_channel::<Value>();
    let writer = tokio::spawn(async move {
        let mut stdout = tokio::io::stdout();
        while let Some(message) = outgoing.recv().await {
            stdout.write_all(format!("{message}\n").as_bytes()).await?;
            stdout.flush().await?;
        }
        Ok::<(), std::io::Error>(())
    });
    let _ = output.send(json!({"type": "ready", "protocol": 1}));
    let mut input = BufReader::new(tokio::io::stdin()).lines();
    let mut runs = HashMap::new();
    let mut tasks: JoinSet<(u64, Result<(), String>)> = JoinSet::new();
    let sessions: Sessions = Arc::new(Mutex::new(HashMap::new()));
    let termination = terminated();
    tokio::pin!(termination);
    let result = loop {
        tokio::select! {
            _ = &mut termination => break Ok(()),
            completed = tasks.join_next(), if !tasks.is_empty() => {
                let (id, result) = completed.expect("nonempty task set").map_err(|error| error.to_string())?;
                runs.remove(&id);
                let _ = output.send(json!({"type": "done", "id": id, "ok": result.is_ok(),
                    "error": result.err()}));
            }
            line = input.next_line() => {
                let line = match line {
                    Ok(Some(line)) => line,
                    Ok(None) => break Ok(()),
                    Err(error) => break Err(error.to_string()),
                };
                let request = match serde_json::from_str::<Request>(&line) {
                    Ok(request) => request,
                    Err(error) => break Err(format!("Invalid helper request: {error}")),
                };
                match request {
                    Request::Shutdown => break Ok(()),
                    Request::Cancel { id } => {
                        if let Some(cancel) = runs.get(&id) {
                            let _ = watch::Sender::send(cancel, true);
                        }
                    }
                    Request::Release { session_id } => {
                        let removed = sessions.lock().await.remove(&session_id);
                        if let Some(session) = removed {
                            tokio::spawn(async move {
                                // Let an active turn abort before removing its event handlers.
                                let _ = timeout(Duration::from_secs(45), async {
                                    while Arc::strong_count(&session) > 1 {
                                        sleep(Duration::from_millis(20)).await;
                                    }
                                }).await;
                                let _ = timeout(Duration::from_secs(5), session.disconnect()).await;
                            });
                        }
                    }
                    Request::Run { id, turn } => {
                        if runs.contains_key(&id) {
                            break Err("Duplicate helper request ID".into());
                        }
                        let (cancel, receiver) = watch::channel(false);
                        runs.insert(id, cancel);
                        let client = client.clone();
                        let root = root.clone();
                        let output = output.clone();
                        let sessions = sessions.clone();
                        tasks.spawn(async move {
                            (id, run_turn(client, root, id, *turn, receiver, output, sessions).await)
                        });
                    }
                }
            }
        }
    };
    for cancel in runs.values() {
        let _ = cancel.send(true);
    }
    let _ = timeout(Duration::from_secs(10), async {
        while tasks.join_next().await.is_some() {}
    })
    .await;
    tasks.abort_all();
    drop(output);
    let _ = writer.await;
    result
}

#[tokio::main]
async fn main() {
    if let Err(error) = start().await {
        eprintln!("{error}");
        std::process::exit(1);
    }
}

async fn start() -> Result<(), String> {
    let mut args = std::env::args().skip(1);
    let mut cli = None;
    let mut root = std::env::current_dir().map_err(|error| error.to_string())?;
    let mut check = false;
    let mut state_dir = None;
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--cli" => cli = args.next().map(PathBuf::from),
            "--cwd" => root = PathBuf::from(args.next().ok_or("Missing --cwd value")?),
            "--check" => check = true,
            "--state-dir" => state_dir = args.next().map(PathBuf::from),
            _ => return Err(format!("Unknown argument: {arg}")),
        }
    }
    root = root.canonicalize().map_err(|error| error.to_string())?;
    let mut options = ClientOptions::default().with_mode(ClientMode::Empty);
    options.transport = github_copilot_sdk::Transport::Stdio;
    options.program =
        CliProgram::Path(cli.ok_or("Pass --cli with the Copilot CLI executable path")?);
    options.working_directory = root.clone();
    options.base_directory =
        Some(state_dir.ok_or("Pass --state-dir for neostar's SDK session storage")?);
    let client = Arc::new(Client::start(options).await.map_err(|error| {
        format!(
            "Cannot start Copilot SDK runtime (check agent.copilot.cmd and CLI version): {error}"
        )
    })?);
    let result = if check {
        match client.get_auth_status().await {
            Ok(status) => {
                println!(
                    "{}",
                    json!({"type": "ready", "protocol": 1, "auth": status})
                );
                Ok(())
            }
            Err(error) => Err(format!("Copilot authentication status: {error}")),
        }
    } else {
        serve(client.clone(), root).await
    };
    let stopped = client
        .stop()
        .await
        .map_err(|error| format!("Copilot shutdown: {error}"));
    result.and(stopped)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn request(value: Value) -> PermissionRequestData {
        serde_json::from_value(value).unwrap()
    }

    #[test]
    fn permissions_restrict_reads_and_deny_write_shell_and_policy_overrides() {
        let root = std::env::current_dir().unwrap().canonicalize().unwrap();
        assert!(permitted(
            &root,
            &request(json!({"kind": "read", "path": "Cargo.toml"}))
        ));
        for value in [
            json!({"kind": "read", "path": "../"}),
            json!({"kind": "read", "path": "Cargo.toml", "managedApprovalRequired": true}),
            json!({"kind": "read", "path": "Cargo.toml", "requestSandboxBypass": true}),
            json!({"kind": "shell", "command": "echo x"}),
            json!({"kind": "write", "path": "Cargo.toml"}),
            json!({}),
        ] {
            assert!(!permitted(&root, &request(value)));
        }
    }

    #[test]
    fn mcp_permissions_only_approve_known_neostar_tools() {
        let root = std::env::current_dir().unwrap();
        assert!(permitted(
            &root,
            &request(json!({
                "kind": "mcp", "serverName": "neostar", "toolName": "check_proof"
            }))
        ));
        for (server, tool) in [("github", "check_proof"), ("neostar", "shell")] {
            assert!(!permitted(
                &root,
                &request(json!({
                    "kind": "mcp", "serverName": server, "toolName": tool
                }))
            ));
        }
        assert!(permitted(
            &root,
            &request(json!({
                "permissionRequest": {"kind": "mcp", "serverName": "neostar", "toolName": "fstar_lookup"}
            }))
        ));
    }

    #[tokio::test]
    #[ignore = "requires NEOSTAR_SDK_PROBE_CONFIG and local Copilot CLI; no model calls"]
    async fn live_mcp_resume_uses_new_token() {
        let fixture: Value = serde_json::from_slice(
            &std::fs::read(std::env::var("NEOSTAR_SDK_PROBE_CONFIG").unwrap()).unwrap(),
        )
        .unwrap();
        let root = PathBuf::from(fixture["root"].as_str().unwrap());
        let mut options = ClientOptions::default().with_mode(ClientMode::Empty);
        options.transport = github_copilot_sdk::Transport::Stdio;
        options.program = CliProgram::Path(fixture["cli"].as_str().unwrap().into());
        options.working_directory = root.clone();
        options.base_directory = Some(fixture["state_dir"].as_str().unwrap().into());
        let client = Client::start(options).await.unwrap();
        let sessions: Sessions = Arc::new(Mutex::new(HashMap::new()));
        let mut id = None;
        for marker in ["first", "second"] {
            let mut turn: Turn = serde_json::from_value(fixture[marker].clone()).unwrap();
            turn.resume = id.clone();
            turn.keep_session = true;
            let session = open_session(&client, &sessions, root.clone(), &turn)
                .await
                .unwrap();
            check_mcp(&session).await.unwrap();
            let tools = session
                .rpc()
                .mcp()
                .list_tools(serde_json::from_value(json!({"serverName": "neostar"})).unwrap())
                .await
                .unwrap();
            let tools = serde_json::to_value(tools).unwrap();
            assert_eq!(tools["tools"][0]["description"], marker);
            id = Some(session.id().to_string());
        }
        client.stop().await.unwrap();
    }
}
