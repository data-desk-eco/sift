"""Filter pi's --mode json event stream into terse `[scope] message`
log lines so headless runs aren't silent. With debug=True, dump every
event as raw JSON (one per line) instead.

Consumed in-process by `sift auto`: pi runs as a subprocess, we iterate
its stdout line-by-line and call format_event on each one."""

from __future__ import annotations

import json
from typing import Iterable


def _short(s: object, n: int = 100) -> str:
    text = " ".join(str(s).split())
    return text if len(text) <= n else text[: n - 1] + "…"


def _args_preview(args: object) -> str:
    if isinstance(args, dict):
        for k in ("command", "cmd", "path", "file_path", "file",
                  "query", "url", "pattern"):
            v = args.get(k)
            if v:
                return _short(v)
        return _short(json.dumps(args, ensure_ascii=False))
    return _short(args)


def _log(scope: str, msg: str = "") -> str:
    tag = f"[{scope}]"
    return f"{tag:<9} {msg}".rstrip()


def stream(lines: Iterable[str], debug: bool = False) -> Iterable[str]:
    """Yield formatted lines for each event in `lines`. State (turn
    counter, accumulated final message) is folded into the iterator."""
    turn = 0
    final_text_parts: list[str] = []

    for raw in lines:
        raw = raw.rstrip("\n")
        if not raw:
            continue
        if debug:
            yield raw

        try:
            ev = json.loads(raw)
        except json.JSONDecodeError:
            if not debug:
                yield _log("raw", raw)
            continue
        if debug:
            continue

        t = ev.get("type")
        if t == "session":
            yield _log("session", (ev.get("id") or "")[:8])
        elif t == "agent_start":
            yield _log("agent", "start")
        elif t == "turn_start":
            turn += 1
            yield _log("turn", str(turn))
        elif t == "tool_execution_start":
            name = ev.get("toolName", "?")
            yield _log("tool", f"{name}: {_args_preview(ev.get('args'))}")
        elif t == "tool_execution_end":
            if ev.get("isError"):
                yield _log("tool!",
                           f"{ev.get('toolName', '?')}: "
                           f"{_short(ev.get('result'), 160)}")
        elif t == "message_end":
            msg = ev.get("message") or {}
            if msg.get("role") == "assistant":
                final_text_parts = [
                    c.get("text", "")
                    for c in msg.get("content", [])
                    if c.get("type") == "text"
                ]
        elif t == "compaction_start":
            yield _log("compact", "start")
        elif t == "compaction_end":
            yield _log("compact", "end")
        elif t == "error":
            yield _log("error", _short(ev.get("message") or ev, 200))
        elif t == "agent_end":
            text = "\n".join(p for p in final_text_parts if p).strip()
            if text:
                yield ""
                yield text
            yield _log("done")
