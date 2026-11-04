#!/usr/bin/env python3
"""Record an F* --ide transcript for use as a test fixture.

usage: record_transcript.py <scenario.json> <out.json>

A scenario is a JSON object:
  {
    "file": "Clean.fst",            # path relative to the scenario file; passed to --ide
    "fstar_exe": "fstar.exe",       # optional
    "steps": [ <step>, ... ]
  }
Each step is a query object {"query": ..., "args": {...}} with these extras:
  "code_file": "Other.fst"   use this file's text as args.code (default: "file")
  "cancel_after": 2.0        (full-buffer only) send cancel after N seconds,
                             then ping until the check reports it finished
The output is {"file": ..., "steps": [{"send": query, "recv": [msg, ...]}, ...]}.
A full-buffer step ends at "full-buffer-finished"; other steps end at the
response carrying the step's query-id.
"""
import json
import os
import select
import subprocess
import sys
import time

scenario_path, out_path = sys.argv[1], sys.argv[2]
scenario = json.load(open(scenario_path))
base = os.path.dirname(os.path.abspath(scenario_path))
fname = scenario["file"]
exe = scenario.get("fstar_exe", "fstar.exe")

proc = subprocess.Popen([exe, "--ide", fname], cwd=base, stdin=subprocess.PIPE,
                        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)


def readline(timeout):
    r, _, _ = select.select([proc.stdout], [], [], timeout)
    if not r:
        return None
    line = proc.stdout.readline()
    if line == "":
        raise SystemExit("F* exited: " + proc.stderr.read())
    return json.loads(line)


def send(q):
    proc.stdin.write(json.dumps(q) + "\n")
    proc.stdin.flush()


greeting = readline(30)
qid = 0
steps = []
for step in scenario["steps"]:
    qid += 1
    q = {"query-id": str(qid), "query": step["query"], "args": dict(step.get("args", {}))}
    if step["query"] == "full-buffer":
        q["args"]["code"] = open(os.path.join(base, step.get("code_file", fname))).read()
    send(q)
    recv = []
    t0 = time.time()
    cancel_at = step.get("cancel_after")
    cancelled = False
    last_ping = time.time()
    while True:
        now = time.time()
        if cancel_at is not None and not cancelled and now - t0 >= cancel_at:
            send({"query-id": "c%d" % qid, "query": "cancel",
                  "args": {"cancel-line": 1, "cancel-column": 0}})
            cancelled = True
            last_ping = now
        # F* only emits the tail of a full-buffer run (and finishes a
        # cancellation) once more input arrives, so keep one ping in flight.
        if step["query"] == "full-buffer" and now - last_ping >= 0.5:
            send({"query-id": "p%d" % qid, "query": "describe-protocol", "args": {}})
            last_ping = now
        msg = readline(0.2)
        if msg is None:
            if now - t0 > 600:
                raise SystemExit("timeout in step %d" % qid)
            continue
        if str(msg.get("query-id", "")).startswith("p"):
            continue
        recv.append(msg)
        if step["query"] == "full-buffer":
            c = msg.get("contents")
            if isinstance(c, dict) and c.get("stage") == "full-buffer-finished":
                break
        elif msg.get("kind") == "response" and msg.get("query-id") == str(qid):
            break
    if step["query"] == "full-buffer":
        # swallow ping responses still in flight
        while True:
            msg = readline(1.0)
            if msg is None:
                break
    steps.append({"send": q, "recv": recv})

proc.kill()
json.dump({"file": fname, "greeting": greeting, "steps": steps}, open(out_path, "w"), indent=1)
print("wrote %s (%d steps)" % (out_path, len(steps)))
