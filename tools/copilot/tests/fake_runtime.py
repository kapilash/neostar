#!/usr/bin/env python3
"""Offline JSON-RPC runtime for testing the actual Rust SDK transport."""
import json
import os
import sys

sessions = {}
sequence = 0


def emit(message):
    body = json.dumps(message).encode()
    sys.stdout.buffer.write(f"Content-Length: {len(body)}\r\n\r\n".encode() + body)
    sys.stdout.buffer.flush()


def event(session, kind, data):
    global sequence
    sequence += 1
    emit({
        "jsonrpc": "2.0", "method": "session.event",
        "params": {"sessionId": session, "event": {
            "id": str(sequence), "timestamp": "2026-01-01T00:00:00Z",
            "parentId": None, "type": kind, "data": data,
        }},
    })


while True:
    headers = {}
    while True:
        line = sys.stdin.buffer.readline()
        if not line:
            sys.exit(0)
        if line == b"\r\n":
            break
        key, value = line.decode().split(":", 1)
        headers[key.lower()] = value.strip()
    message = json.loads(sys.stdin.buffer.read(int(headers["content-length"])))
    with open(os.environ["NEOSTAR_SDK_TEST_LOG"], "a") as log:
        log.write(json.dumps(message) + "\n")
    if "method" not in message or "id" not in message:
        continue
    method = message["method"]
    params = message.get("params", {})
    session = params.get("sessionId")
    result = {"success": True}
    if method == "connect":
        result = {"ok": True, "protocolVersion": 3, "version": "offline-test"}
    elif method in ("session.create", "session.resume"):
        session = session or f"session-{len(sessions) + 1}"
        sessions[session] = params["mcpServers"]["neostar"]["headers"]["Authorization"]
        result = {"sessionId": session}
    elif method == "session.mcp.list":
        result = {"servers": [{"name": "neostar", "status":
            "disabled" if os.environ.get("NEOSTAR_SDK_TEST_DISABLE_MCP") else "connected"}]}
    elif method == "session.mcp.restartServer":
        sessions[session] = params["config"]["headers"]["Authorization"]
    elif method == "session.send":
        result = {"messageId": "answer"}
    emit({"jsonrpc": "2.0", "id": message["id"], "result": result})
    if method == "session.send":
        event(session, "assistant.message_delta", {
            "messageId": "answer", "deltaContent": sessions[session],
        })
        if params["prompt"] != "wait":
            event(session, "session.idle", {})
