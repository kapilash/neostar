#!/usr/bin/env python3
"""Fake GitHub Copilot CLI (prompt mode, --output-format json) for tests.

Reads a plan from $NEOSTAR_FAKE_COPILOT_PLAN and logs {argv, cwd, stdin} to
$NEOSTAR_FAKE_COPILOT_LOG, like fake_claude.py (see fake_agent.py). It connects
to the MCP server from --additional-mcp-config @file the way Copilot 1.0.103
does: `server/discover` first (expected to fail with -32601), then
`initialize`, `notifications/initialized` and `tools/list`. It then reports the
server in `session.mcp_servers_loaded`. Actions:
  {"replay": "path.jsonl"}           print the lines of a recorded JSONL file
  {"text": "..."}                    stream one assistant message as deltas
  {"call": name, "args": {...}}      call an MCP tool; emits tool.execution_* events
  {"call_until_ok": [[name, args], ...]}  call in order, stop at the first non-error
  {"sleep": seconds}
  {"result": {...}}                  print a result line (sessionId filled in)
  {"stderr": "...", "exit": code}    write to stderr and exit (no result line)
  {"mcp_status": "disabled"}         report neostar's server with this status
                                     instead of connecting (must come first)
If the plan has no result action, a result with exitCode 0 is printed at the end.
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
plan = load_plan("NEOSTAR_FAKE_COPILOT_PLAN", "NEOSTAR_FAKE_COPILOT_LOG", argv, stdin)

session = None
for a in argv:
    if a.startswith("--resume="):
        session = a.split("=", 1)[1]
session = session or str(uuid.uuid4())


def out(t, data=None, **extra):
    obj = dict({"type": t, "data": data or {}, "id": str(uuid.uuid4()), "timestamp": "2026-01-01T00:00:00.000Z"}, **extra)
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


def handshake(server):
    m = Mcp(server)
    disc = m.rpc("server/discover", {"_meta": {"io.modelcontextprotocol/protocolVersion": "2026-07-28"}})
    if (disc.get("error") or {}).get("code") != -32601:
        raise SystemExit("fake copilot: expected -32601 for server/discover, got %r" % (disc,))
    init = m.rpc("initialize", {"protocolVersion": "2025-11-25", "capabilities": {},
                                "clientInfo": {"name": "copilot-cli", "version": "1.0.103"}})
    if "result" not in init:
        raise SystemExit("fake copilot: initialize failed: %r" % (init,))
    m.rpc("notifications/initialized", notify=True)
    tools = m.rpc("tools/list", {}).get("result", {}).get("tools", [])
    return m, tools


mcp = None
status = "connected"
if plan and "mcp_status" in plan[0]:
    status = plan[0]["mcp_status"]
elif "--additional-mcp-config" in argv:
    path = argv[argv.index("--additional-mcp-config") + 1]
    cfg = json.load(open(path[1:] if path.startswith("@") else path))
    mcp, tool_list = handshake(cfg["mcpServers"]["neostar"])
    out("session.mcp_server_tools_loaded", {"serverName": "neostar", "toolCount": len(tool_list)}, ephemeral=True)
out("session.mcp_servers_loaded", {"servers": [
    {"name": "github-mcp-server", "status": "disabled", "source": "builtin"},
    {"name": "neostar", "status": status}]}, ephemeral=True)
out("user.message", {"content": stdin})


def message(text):
    mid = str(uuid.uuid4())
    out("assistant.message_start", {"messageId": mid, "phase": "final_answer"}, ephemeral=True)
    for i in range(0, len(text), 7):
        out("assistant.message_delta", {"messageId": mid, "deltaContent": text[i:i + 7]}, ephemeral=True)
        time.sleep(0.005)
    out("assistant.message", {"messageId": mid, "content": text, "toolRequests": []})


def call(name, args):
    cid = "call_" + uuid.uuid4().hex[:12]
    out("tool.execution_start", {"toolCallId": cid, "toolName": "neostar-" + name, "arguments": args,
                                 "mcpServerName": "neostar", "mcpToolName": name})
    res = mcp.call(name, args)
    text = "".join(c.get("text", "") for c in res.get("content") or [])
    out("tool.execution_complete", {"toolCallId": cid, "success": not res.get("isError"),
                                    "result": {"content": text}})
    return res


done = False
for act in plan:
    if "replay" in act:
        for line in open(act["replay"]):
            sys.stdout.write(line)
        sys.stdout.flush()
        done = True
    elif "text" in act:
        message(act["text"])
    elif "call" in act:
        call(act["call"], act.get("args", {}))
    elif "call_until_ok" in act:
        for name, args in act["call_until_ok"]:
            if not call(name, args).get("isError"):
                break
    elif "sleep" in act:
        time.sleep(act["sleep"])
    elif "result" in act:
        out("assistant.idle", ephemeral=True)
        sys.stdout.write(json.dumps(dict({"type": "result", "sessionId": session, "exitCode": 0,
                                          "usage": {"premiumRequests": 1}}, **act["result"])) + "\n")
        sys.stdout.flush()
        done = True
    elif "exit" in act:
        sys.stderr.write(act.get("stderr", ""))
        sys.exit(act["exit"])
if not done:
    out("assistant.idle", ephemeral=True)
    sys.stdout.write(json.dumps({"type": "result", "sessionId": session, "exitCode": 0,
                                 "usage": {"premiumRequests": 1}}) + "\n")
    sys.stdout.flush()
