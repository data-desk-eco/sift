"""SQLite-backed store for aliases (`r1`, `r2`, …), entity blobs, the
response cache, and the property-edge graph, plus the `see_entity`
ingester that walks nested property refs so every entity the agent
sees gets a stable alias on first sight (and the alias resolves
without a round-trip later)."""

from __future__ import annotations

import hashlib
import json
import re
import sqlite3
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterator

from .errors import CommandError
from .render import first_label, first_string, short
from .schemas import REF_PROPERTIES


def iso_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


SCHEMA = """
CREATE TABLE IF NOT EXISTS entities (
    id TEXT PRIMARY KEY,
    schema TEXT NOT NULL,
    caption TEXT,
    name TEXT,
    properties TEXT,            -- JSON
    collection_id TEXT,
    server TEXT,
    has_full_body INTEGER NOT NULL DEFAULT 0,
    first_seen TEXT NOT NULL,
    updated_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS aliases (
    alias TEXT PRIMARY KEY,
    n INTEGER NOT NULL UNIQUE,
    entity_id TEXT NOT NULL UNIQUE,
    assigned_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS cache (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL,
    set_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS edges (
    src_id TEXT NOT NULL,
    prop TEXT NOT NULL,
    dst_id TEXT NOT NULL,
    first_seen TEXT NOT NULL,
    PRIMARY KEY (src_id, prop, dst_id)
);
CREATE INDEX IF NOT EXISTS idx_edges_src ON edges(src_id, prop);
CREATE INDEX IF NOT EXISTS idx_edges_dst ON edges(dst_id, prop);
"""

# Properties whose bare-string list members are entity ids, not labels.
# Dict-with-{id,schema} refs are caught everywhere; this catches the
# remaining bare-id references (ancestors, sometimes parent).
BARE_STRING_REF_PROPS: set[str] = set(REF_PROPERTIES) | {"ancestors"}


def iter_property_edges(props: dict) -> Iterator[tuple[str, str]]:
    """Yield (prop, dst_entity_id) for every entity reference in a properties
    dict. Recognises dict-with-id-and-schema refs anywhere, and bare-string
    refs only on properties known to hold entity ids."""
    if not isinstance(props, dict):
        return
    for prop, value in props.items():
        yield from _ref_ids(prop, value)


def _ref_ids(prop: str, value: Any) -> Iterator[tuple[str, str]]:
    if value is None:
        return
    if isinstance(value, str):
        if prop in BARE_STRING_REF_PROPS and value:
            yield prop, value
        return
    if isinstance(value, dict):
        eid = value.get("id")
        sch = value.get("schema")
        if isinstance(eid, str) and eid and isinstance(sch, str):
            yield prop, eid
        return
    if isinstance(value, list):
        for item in value:
            yield from _ref_ids(prop, item)


SCHEMA_VERSION = 1


class Store:
    def __init__(self, db_path: Path) -> None:
        db_path.parent.mkdir(parents=True, exist_ok=True)
        self.db_path = db_path
        self.conn = sqlite3.connect(str(db_path))
        self.conn.row_factory = sqlite3.Row
        self.conn.executescript(SCHEMA)
        self._migrate()

    def _migrate(self) -> None:
        """Apply forward migrations against existing databases. Schema CREATE
        statements above are idempotent, so this only needs to handle data
        backfills (e.g. populating `edges` from existing entity blobs)."""
        ver = self.conn.execute("PRAGMA user_version").fetchone()[0]
        if ver < 1:
            for row in self.conn.execute(
                "SELECT id, properties, first_seen FROM entities WHERE properties IS NOT NULL"
            ).fetchall():
                try:
                    props = json.loads(row["properties"])
                except (json.JSONDecodeError, TypeError):
                    continue
                for prop, dst in iter_property_edges(props):
                    self.conn.execute(
                        "INSERT OR IGNORE INTO edges VALUES (?, ?, ?, ?)",
                        (row["id"], prop, dst, row["first_seen"]),
                    )
            self.conn.execute(f"PRAGMA user_version = {SCHEMA_VERSION}")
            self.conn.commit()

    # ----- entities -------------------------------------------------------

    def remember(
        self,
        eid: str,
        schema: str,
        caption: str | None,
        name: str | None,
        properties: dict | None,
        collection_id: str | None,
        server: str | None,
        full_body: bool = False,
    ) -> None:
        now = iso_now()
        props_json = json.dumps(properties) if properties is not None else None
        existing = self.conn.execute(
            "SELECT properties, collection_id, server, has_full_body FROM entities WHERE id=?",
            (eid,),
        ).fetchone()
        if existing is None:
            self.conn.execute(
                "INSERT INTO entities VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                (
                    eid, schema, caption, name, props_json,
                    collection_id, server, 1 if full_body else 0, now, now,
                ),
            )
        else:
            # Preserve old props if new are empty; preserve has_full_body=1 once set.
            new_props = props_json if props_json else existing["properties"]
            new_full = 1 if (full_body or existing["has_full_body"]) else 0
            new_cid = collection_id or existing["collection_id"]
            new_srv = server or existing["server"]
            self.conn.execute(
                """UPDATE entities SET
                       schema=?, caption=COALESCE(?, caption), name=COALESCE(?, name),
                       properties=?, collection_id=?, server=?, has_full_body=?,
                       updated_at=? WHERE id=?""",
                (schema, caption, name, new_props, new_cid, new_srv, new_full, now, eid),
            )
        self.conn.commit()

    def get_entity(self, eid: str) -> dict | None:
        row = self.conn.execute("SELECT * FROM entities WHERE id=?", (eid,)).fetchone()
        return dict(row) if row else None

    def cached_properties(self, eid: str) -> dict | None:
        row = self.conn.execute(
            "SELECT properties FROM entities WHERE id=?", (eid,)
        ).fetchone()
        if row and row[0]:
            return json.loads(row[0])
        return None

    def has_full_body(self, eid: str) -> bool:
        row = self.conn.execute(
            "SELECT has_full_body FROM entities WHERE id=?", (eid,)
        ).fetchone()
        return bool(row and row[0])

    def collection_of(self, eid: str) -> str | None:
        row = self.conn.execute(
            "SELECT collection_id FROM entities WHERE id=?", (eid,)
        ).fetchone()
        return row[0] if row else None

    # ----- edges ----------------------------------------------------------

    def record_edges(self, src_id: str, props: dict | None) -> None:
        """Persist (src, prop, dst) edges for every entity ref in `props`.
        Idempotent — repeated calls keep the original `first_seen`."""
        if not props:
            return
        now = iso_now()
        for prop, dst in iter_property_edges(props):
            self.conn.execute(
                "INSERT OR IGNORE INTO edges VALUES (?, ?, ?, ?)",
                (src_id, prop, dst, now),
            )
        self.conn.commit()

    # ----- aliases --------------------------------------------------------

    def alias_for(self, eid: str) -> str | None:
        row = self.conn.execute(
            "SELECT alias FROM aliases WHERE entity_id=?", (eid,)
        ).fetchone()
        return row[0] if row else None

    def assign_alias(self, eid: str) -> str:
        existing = self.alias_for(eid)
        if existing:
            return existing
        row = self.conn.execute("SELECT MAX(n) FROM aliases").fetchone()
        n = (row[0] or 0) + 1
        alias = f"r{n}"
        self.conn.execute(
            "INSERT INTO aliases VALUES (?, ?, ?, ?)", (alias, n, eid, iso_now())
        )
        self.conn.commit()
        return alias

    def resolve_alias(self, alias_or_id: str) -> str:
        s = alias_or_id.strip()
        if re.fullmatch(r"r\d+", s):
            row = self.conn.execute(
                "SELECT entity_id FROM aliases WHERE alias=?", (s,)
            ).fetchone()
            if not row:
                raise CommandError(
                    f"unknown alias '{s}'",
                    "run a search first or pass the raw entity ID",
                )
            return row[0]
        return s

    def resolve_optional(self, alias_or_id: str | None) -> str | None:
        if not alias_or_id:
            return None
        s = alias_or_id.strip()
        if not s:
            return None
        if re.fullmatch(r"r\d+", s):
            return self.resolve_alias(s)
        return s

    # ----- response cache -------------------------------------------------

    def cache_get(self, key: str) -> dict | None:
        row = self.conn.execute(
            "SELECT value FROM cache WHERE key=?", (key,)
        ).fetchone()
        return json.loads(row[0]) if row else None

    def cache_set(self, key: str, value: dict) -> None:
        self.conn.execute(
            "INSERT OR REPLACE INTO cache VALUES (?, ?, ?)",
            (key, json.dumps(value), iso_now()),
        )
        self.conn.commit()

    @staticmethod
    def cache_key(command: str, args: dict) -> str:
        payload = json.dumps({"command": command, "args": args}, sort_keys=True, default=str)
        return hashlib.sha256(payload.encode()).hexdigest()[:16]


# ---------------------------------------------------------------------------
# Entity ingestion — recursively cache nested entity blobs and assign
# aliases so every reference the model sees has a stable short name.
# ---------------------------------------------------------------------------


def see_entity(
    store: Store,
    entity: dict,
    server: str | None,
    collection_id: str | None,
    full_body: bool = False,
    _seen: set[str] | None = None,
) -> str:
    eid = entity.get("id")
    if not isinstance(eid, str) or not eid:
        return ""
    if _seen is None:
        _seen = set()
    if eid in _seen:
        return store.alias_for(eid) or ""

    schema = entity.get("schema") or "Thing"
    caption = entity.get("caption")
    props = entity.get("properties") or {}
    name = (
        first_string(props.get("name"))
        or first_string(props.get("title"))
        or first_string(props.get("subject"))
        or caption
        or first_string(props.get("fileName"))
    )

    # Collection on the entity may be a dict, a string id, or absent.
    cid = collection_id
    coll = entity.get("collection")
    if isinstance(coll, dict):
        cid = coll.get("collection_id") or coll.get("foreign_id") or coll.get("id") or cid
    elif isinstance(entity.get("collection_id"), str):
        cid = entity["collection_id"]

    store.remember(
        eid=eid, schema=schema, caption=caption, name=name,
        properties=props if props else None,
        collection_id=cid, server=server, full_body=full_body,
    )
    store.record_edges(eid, props)
    alias = store.assign_alias(eid)

    # Aleph inlines nested entity blobs for property refs (emitters, recipients,
    # mentions, parent, …). Cache them all so the agent can refer to them by
    # alias without an extra round-trip.
    next_seen = _seen | {eid}
    for value in props.values():
        _recurse_into(store, value, server, cid, next_seen)
    return alias


def _recurse_into(
    store: Store, value: Any, server: str | None,
    collection_id: str | None, seen: set[str],
) -> None:
    if isinstance(value, dict):
        if isinstance(value.get("id"), str) and isinstance(value.get("schema"), str):
            see_entity(store, value, server, collection_id, full_body=False, _seen=seen)
    elif isinstance(value, list):
        for item in value:
            _recurse_into(store, item, server, collection_id, seen)


def format_ftm_refs(store: Store, value: Any) -> str:
    if value is None:
        return ""
    items: list[tuple[str, str]] = []

    def add(d: dict) -> None:
        eid = d.get("id")
        if not isinstance(eid, str):
            return
        alias = store.alias_for(eid) or "?"
        props = d.get("properties") or {}
        name_list = props.get("name") or []
        if isinstance(name_list, list) and name_list:
            display = name_list[0]
        else:
            display = d.get("caption") or first_label(props.get("email")) or eid[:10]
        items.append((alias, display))

    if isinstance(value, dict):
        add(value)
    elif isinstance(value, list):
        for item in value:
            if isinstance(item, dict):
                add(item)
            elif isinstance(item, str):
                # Bare-id reference. Look up what we know about it locally.
                stub = store.get_entity(item)
                alias = store.alias_for(item) or "?"
                display = (stub or {}).get("name") or (stub or {}).get("caption") or item[:10]
                items.append((alias, display))
    return ", ".join(f"{a} {short(d, width=28)}" for a, d in items)
