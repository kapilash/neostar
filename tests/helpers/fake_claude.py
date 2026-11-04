#!/usr/bin/env python3
"""Fake `claude -p` for tests.

Reads a plan from $NEOSTAR_FAKE_CLAUDE_PLAN (JSON list of actions) and records
its argv, cwd and stdin to $NEOSTAR_FAKE_CLAUDE_LOG (one JSON object per run).
Actions:
  {"replay": "path.jsonl"}           print the lines of a stream-json file
  {"text": "..."}                    stream text as content_block_delta events
  {"call": name, "args": {...}}      call an MCP tool on the configured server;
                                     emits tool_use / tool_result lines
  {"call_until_ok": [[name, args], ...]}  call in order, stop at the first non-error
  {"sleep": seconds}
  {"result": {...}}                  print a result line (session_id filled in)
  {"stderr": "...", "exit": code}    write to stderr and exit
If the plan has no result action, a success result is printed at the end.
Multiple runs: $NEOSTAR_FAKE_CLAUDE_PLAN may hold {"runs": [plan, plan, ...]};
run k uses plan k (see fake_agent.py).
"""
import json
import os
import sys
import time
import uuid

sys.dont_write_bytecode = True  # no __pycache__ in the repo
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fake_agent import Mcp, load_plan  # noqa: E402

argv = sys.argv[1:]
stdin = sys.stdin.read()
plan = load_plan("NEOSTAR_FAKE_CLAUDE_PLAN", "NEOSTAR_FAKE_CLAUDE_LOG", argv, stdin)

session = None
if "--resume" in argv:
    session = argv[argv.index("--resume") + 1]
session = session or str(uuid.uuid4())


def out(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


mcp = None
if "--mcp-config" in argv:
    cfg = json.load(open(argv[argv.index("--mcp-config") + 1]))
    mcp = Mcp(cfg["mcpServers"]["neostar"])


def call(name, args):
    res = mcp.call(name, args)
    tid = "toolu_" + uuid.uuid4().hex[:8]
    out({"type": "assistant", "message": {"content": [
        {"type": "tool_use", "id": tid, "name": "mcp__neostar__" + name, "input": args}]}})
    out({"type": "user", "message": {"content": [
        {"type": "tool_result", "tool_use_id": tid, "content": res.get("content"), "is_error": res.get("isError")}]}})
    return res


out({"type": "system", "subtype": "init", "session_id": session, "tools": ["Glob", "Grep", "Read"]})
done = False
for act in plan:
    if "replay" in act:
        for line in open(act["replay"]):
            sys.stdout.write(line)
        sys.stdout.flush()
        done = True
    elif "text" in act:
        out({"type": "stream_event", "event": {"type": "content_block_start", "index": 0,
                                               "content_block": {"type": "text", "text": ""}}})
        t = act["text"]
        for i in range(0, len(t), 7):
            out({"type": "stream_event", "event": {"type": "content_block_delta", "index": 0,
                                                   "delta": {"type": "text_delta", "text": t[i:i + 7]}}})
            time.sleep(0.005)
    elif "call" in act:
        call(act["call"], act.get("args", {}))
    elif "call_until_ok" in act:
        for name, args in act["call_until_ok"]:
            if not call(name, args).get("isError"):
                break
    elif "sleep" in act:
        time.sleep(act["sleep"])
    elif "result" in act:
        r = dict({"type": "result", "subtype": "success", "is_error": False, "session_id": session}, **act["result"])
        out(r)
        done = True
    elif "exit" in act:
        sys.stderr.write(act.get("stderr", ""))
        sys.exit(act["exit"])
if not done:
    out({"type": "result", "subtype": "success", "is_error": False, "session_id": session, "result": ""})
