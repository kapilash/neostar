"""Shared parts of the fake agents (fake_claude.py, fake_copilot.py).

Plans are JSON lists of actions, read from an environment variable. A plan may
also be {"runs": [plan, plan, ...]}: run k uses plan k (counted with a file
next to the log). Every run is logged as one JSON object {argv, cwd, stdin}.
"""
import json
import os
import urllib.request
import urllib.error


def load_plan(plan_var, log_var, argv, stdin):
    log = os.environ.get(log_var)
    plan = json.loads(os.environ.get(plan_var, "[]"))
    if isinstance(plan, dict):
        runs = plan["runs"]
        counter = (log or "/tmp/" + plan_var.lower()) + ".count"
        k = int(open(counter).read()) if os.path.exists(counter) else 0
        open(counter, "w").write(str(k + 1))
        plan = runs[min(k, len(runs) - 1)]
    if log:
        with open(log, "a") as f:
            f.write(json.dumps({"argv": argv, "cwd": os.getcwd(), "stdin": stdin}) + "\n")
    return plan


class Mcp:
    """Minimal MCP client for neostar's streamable-HTTP server (JSON responses)."""

    def __init__(self, server):
        self.url = server["url"]
        self.headers = dict(server.get("headers") or {})
        self.next_id = 1

    def rpc(self, method, params=None, notify=False):
        msg = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            msg["params"] = params
        if not notify:
            msg["id"] = self.next_id
            self.next_id += 1
        req = urllib.request.Request(self.url, data=json.dumps(msg).encode(), headers=dict(self.headers, **{
            "Content-Type": "application/json", "Accept": "application/json, text/event-stream"}))
        try:
            body = urllib.request.urlopen(req, timeout=60).read()
        except urllib.error.HTTPError as e:
            return {"http_status": e.code}
        return json.loads(body) if body else {}

    def call(self, name, args):
        return self.rpc("tools/call", {"name": name, "arguments": args}).get("result") or {}
