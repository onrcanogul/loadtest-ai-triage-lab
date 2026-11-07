#!/usr/bin/env python3
"""Transparent stdio proxy for an MCP server that writes an audit trail of every tool call.

    mcp-audit-proxy.py <audit.jsonl> -- <server command...>

The client (an AI agent CLI) talks JSON-RPC over newline-delimited stdio to this process, which forwards
every byte unchanged to the real server and back. Only `tools/call` requests and their responses are
recorded, as one JSON object per line:
    {"ts": "...", "dir": "call",   "id": 7, "tool": "query_loki_logs", "args": {...}}
    {"ts": "...", "dir": "result", "id": 7, "tool": "query_loki_logs", "isError": false, "bytes": 1234}
Purpose (scripts/triage.sh): prove that a report was produced from real Grafana queries ("who asked what,
when"), and reject a report when the agent never called a tool. Arguments are logged verbatim: they are
LogQL queries and time ranges, never log contents; results are logged by size only.
"""
import json, os, signal, subprocess, sys, threading, datetime

def now():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"

def main():
    argv = sys.argv[1:]
    if len(argv) < 3 or argv[1] != "--":
        sys.stderr.write(__doc__); sys.exit(2)
    audit_path, cmd = argv[0], argv[2:]
    audit = open(audit_path, "a", buffering=1)
    lock = threading.Lock()
    pending = {}  # request id -> tool name

    def log(obj):
        with lock:
            audit.write(json.dumps(obj, ensure_ascii=False) + "\n")

    child = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=sys.stderr, bufsize=0)
    stop = lambda *_: child.terminate()
    signal.signal(signal.SIGTERM, stop); signal.signal(signal.SIGINT, stop)

    def upstream():  # client -> server
        for raw in sys.stdin.buffer:
            try:
                msg = json.loads(raw)
                if msg.get("method") == "tools/call":
                    p = msg.get("params") or {}
                    pending[msg.get("id")] = p.get("name")
                    log({"ts": now(), "dir": "call", "id": msg.get("id"), "tool": p.get("name"), "args": p.get("arguments")})
            except Exception:
                pass
            try:
                child.stdin.write(raw); child.stdin.flush()
            except (BrokenPipeError, ValueError):
                break
        try: child.stdin.close()
        except Exception: pass

    def downstream():  # server -> client
        for raw in child.stdout:
            try:
                msg = json.loads(raw)
                rid = msg.get("id")
                if rid in pending and ("result" in msg or "error" in msg):
                    res = msg.get("result") or {}
                    log({"ts": now(), "dir": "result", "id": rid, "tool": pending.pop(rid),
                         "isError": bool(res.get("isError")) or "error" in msg, "bytes": len(raw)})
            except Exception:
                pass
            sys.stdout.buffer.write(raw); sys.stdout.buffer.flush()

    t = threading.Thread(target=upstream, daemon=True); t.start()
    downstream()
    rc = child.wait()
    audit.close()
    sys.exit(rc)

if __name__ == "__main__":
    main()
