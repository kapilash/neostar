"""Tiny stand-in for `fstar.exe --ide` used by transport tests.

Prints a protocol-info greeting, then answers each query line with a progress
message on a sub-id and a response echoing the query, split across two
writes to exercise line reassembly. `crash` makes it exit with stderr output.
"""
import json
import sys

sys.stdout.write(json.dumps({"kind": "protocol-info", "version": 3, "features": []}) + "\n")
sys.stdout.flush()
for line in sys.stdin:
    q = json.loads(line)
    qid = q["query-id"]
    if q["query"] == "crash":
        sys.stderr.write("fatal: simulated crash\n")
        sys.stderr.flush()
        sys.exit(3)
    msg = json.dumps({"kind": "message", "query-id": qid + ".1", "level": "progress",
                      "contents": {"stage": "full-buffer-fragment-started"}})
    resp = json.dumps({"kind": "response", "query-id": qid, "status": "success",
                       "response": {"echo": q["args"], "query": q["query"]}})
    data = msg + "\n" + resp + "\n"
    half = len(data) // 2
    sys.stdout.write(data[:half]); sys.stdout.flush()
    sys.stdout.write(data[half:]); sys.stdout.flush()
