"""Render helpers — pure functions for shaping API responses into the
terse `[header] / body / Next:` envelope sift commands emit, plus the
small string utilities (label extraction, subject normalisation, email
sender cleanup) used across commands."""

from __future__ import annotations

import re
from typing import Any

RULE = "─" * 60
DEFAULT_BODY_CHARS = 1500


def envelope(header: str, body: str, next_actions: list[str] | None = None,
             cached: bool = False) -> str:
    tag = "  (cached)" if cached else ""
    parts = [f"[{header}]{tag}", RULE, body.rstrip()]
    if next_actions:
        parts.append(RULE)
        parts.append("Next: " + "  |  ".join(next_actions))
    return "\n".join(parts)


def truncate(text: str, max_chars: int = DEFAULT_BODY_CHARS) -> str:
    if not text:
        return ""
    if len(text) <= max_chars:
        return text
    return text[:max_chars].rstrip() + f"\n[…+{len(text) - max_chars} chars truncated, pass full=true]"


def short(text: str | None, width: int = 60) -> str:
    if not text:
        return ""
    clean = text.replace("\n", " ").strip()
    if len(clean) <= width:
        return clean
    return clean[: width - 1] + "…"


def extract_label(value: Any) -> str:
    if value is None:
        return ""
    if isinstance(value, dict):
        for k in ("label", "name", "id"):
            v = value.get(k)
            if v:
                return str(v)
        return ""
    if isinstance(value, list):
        return ", ".join(filter(None, (extract_label(v) for v in value)))
    return str(value)


def first_label(value: Any) -> str:
    if isinstance(value, list):
        return extract_label(value[0]) if value else ""
    return extract_label(value)


def first_string(value: Any) -> str | None:
    if isinstance(value, str) and value:
        return value
    if isinstance(value, list) and value:
        v = value[0]
        if isinstance(v, str) and v:
            return v
    return None


_SUBJECT_PREFIX_RE = re.compile(r"^(?:\s*(?:re|fwd?|aw|sv|tr|antw|wg)\s*:\s*)+", re.IGNORECASE)


def normalize_subject(subject: str | None) -> str:
    if not subject:
        return ""
    return re.sub(r"\s+", " ", _SUBJECT_PREFIX_RE.sub("", subject)).strip().lower()


def strip_email_address(sender: str) -> str:
    if not sender:
        return ""
    m = re.match(r"^\s*(.+?)\s*<[^>]+>\s*$", sender)
    return m.group(1) if m else sender


def first_entity_ref_id(value: Any) -> str | None:
    if isinstance(value, str) and value:
        return value
    if isinstance(value, dict) and isinstance(value.get("id"), str):
        return value["id"]
    if isinstance(value, list):
        for item in value:
            r = first_entity_ref_id(item)
            if r:
                return r
    return None


def referenced_id_strings(value: Any) -> list[str]:
    out: list[str] = []

    def walk(v: Any) -> None:
        if isinstance(v, str) and v:
            out.append(v)
        elif isinstance(v, dict):
            i = v.get("id")
            if isinstance(i, str) and i:
                out.append(i)
        elif isinstance(v, list):
            for x in v:
                walk(x)

    walk(value)
    return out
