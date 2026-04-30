#!/usr/bin/env python3
"""
sift-log: filter pi's --mode json event stream into terse `[scope] message`
log lines so headless runs aren't silent. With SIFT_DEBUG=1, dump every
event as raw JSON (one per line) instead.
"""
import json
import os
import sys

DEBUG = os.environ.get("SIFT_DEBUG") == "1"


def short(s, n=100):
    s = " ".join(str(s).split())
    return s if len(s) <= n else s[: n - 1] + "…"


def args_preview(args):
    if isinstance(args, dict):
        for k in ("command", "cmd", "path", "file_path", "file", "query", "url", "pattern"):
            if k in args and args[k]:
                return short(args[k])
        return short(json.dumps(args, ensure_ascii=False))
    return short(args)


def emit(line):
    print(line, flush=True)


def log(scope, msg=""):
    tag = f"[{scope}]"
    emit(f"{tag:<9} {msg}".rstrip())


turn = 0
final_text_parts = []

for raw in sys.stdin:
    raw = raw.rstrip("\n")
    if not raw:
        continue

    if DEBUG:
        emit(raw)

    try:
        ev = json.loads(raw)
    except json.JSONDecodeError:
        if not DEBUG:
            log("raw", raw)
        continue

    if DEBUG:
        # In debug mode the raw JSON is enough; skip the formatted line.
        continue

    t = ev.get("type")

    if t == "session":
        sid = (ev.get("id") or "")[:8]
        log("session", sid)
    elif t == "agent_start":
        log("agent", "start")
    elif t == "turn_start":
        turn += 1
        log("turn", turn)
    elif t == "tool_execution_start":
        name = ev.get("toolName", "?")
        log("tool", f"{name}: {args_preview(ev.get('args'))}")
    elif t == "tool_execution_end":
        if ev.get("isError"):
            log("tool!", f"{ev.get('toolName', '?')}: {short(ev.get('result'), 160)}")
    elif t == "message_end":
        msg = ev.get("message") or {}
        if msg.get("role") == "assistant":
            final_text_parts = [
                c.get("text", "")
                for c in msg.get("content", [])
                if c.get("type") == "text"
            ]
    elif t == "compaction_start":
        log("compact", "start")
    elif t == "compaction_end":
        log("compact", "end")
    elif t == "error":
        log("error", short(ev.get('message') or ev, 200))
    elif t == "agent_end":
        text = "\n".join(p for p in final_text_parts if p).strip()
        if text:
            emit("")
            emit(text)
        log("done")
