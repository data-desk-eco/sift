"""Research-tool implementations: search, read, sources, hubs, similar,
expand, browse, tree (network-bound, take a client) plus neighbors,
recall, cache stats/clear, sql (local-only, read against the cache
DB). Each network command takes (client, store, args); each local
command takes (store, args). All return a formatted envelope string."""

from __future__ import annotations

import json
import sqlite3
from datetime import datetime, timedelta, timezone
from typing import Any

from .client import AlephClient
from .errors import CommandError
from .render import (
    RULE,
    envelope,
    extract_label,
    first_entity_ref_id,
    first_label,
    normalize_subject,
    referenced_id_strings,
    short,
    strip_email_address,
    table,
    truncate,
)
from .schemas import (
    ANY_TYPE_SCHEMAS,
    FOLDER_SCHEMAS,
    PARTY_SCHEMAS,
    REF_PROPERTIES,
    TREE_DOC_SCHEMAS,
    TYPE_TO_SCHEMA,
)
from .store import Store, see_entity, format_ftm_refs


def _search_params(query: str, type_: str, limit: int, collection: str | None,
                   offset: int) -> dict:
    p: dict[str, Any] = {"q": query, "limit": limit}
    if offset > 0:
        p["offset"] = offset
    if type_ == "any":
        p["filter:schemata"] = ANY_TYPE_SCHEMAS
    elif type_ in TYPE_TO_SCHEMA:
        p["filter:schemata"] = TYPE_TO_SCHEMA[type_]
    if collection:
        p["filter:collection_id"] = collection
    return p


def _email_row(alias: str, entity: dict) -> tuple[str, str, str, str]:
    props = entity.get("properties") or {}
    date = first_label(props.get("date"))[:10] or ""
    sender = strip_email_address(first_label(props.get("from")) or "unknown")
    subject = first_label(props.get("subject")) or entity.get("title") or "(no subject)"
    return alias, date, short(sender, 30), short(subject, 80)


def _generic_row(alias: str, entity: dict) -> tuple[str, str, str, str]:
    props = entity.get("properties") or {}
    schema = entity.get("schema") or ""
    # Subject wins for emails (filenames look like "202.eml" — useless);
    # everything else uses title/name/fileName ordering.
    candidates = ["subject", "title", "name", "fileName"] if schema == "Email" \
        else ["title", "name", "fileName", "subject"]
    title = next(
        (first_label(props.get(k)) for k in candidates if first_label(props.get(k))),
        entity.get("title") or entity.get("name") or "(untitled)",
    )
    date = (first_label(props.get("date")) or first_label(props.get("createdAt")))[:10]
    return alias, date, schema, short(title, 80)


def _dedupe_emails(results: list[dict]) -> tuple[list[dict], int]:
    """Collapse same-subject emails to a single representative."""
    groups: dict[str, list[dict]] = {}
    order: list[str] = []
    for r in results:
        props = r.get("properties") or {}
        subj = first_label(props.get("subject"))
        key = normalize_subject(subj) if subj else (r.get("id") or "")
        if key not in groups:
            order.append(key)
            groups[key] = []
        groups[key].append(r)
    kept = []
    dropped = 0
    for k in order:
        members = sorted(groups[k], key=lambda r: r.get("id") or "")
        kept.append(members[0])
        dropped += len(members) - 1
    return kept, dropped


def cmd_search(client: AlephClient, store: Store, args: dict) -> str:
    query = args.get("query") or ""
    type_ = args.get("type") or "any"
    limit = int(args.get("limit") or 10)
    offset = int(args.get("offset") or 0)
    collection = args.get("collection")
    sort_by_date = args.get("sort") == "date"
    no_cache = bool(args.get("no_cache"))

    emitter_id = store.resolve_optional(args.get("emitter"))
    recipient_id = store.resolve_optional(args.get("recipient"))
    mentions_id = store.resolve_optional(args.get("mentions"))
    date_from = args.get("date_from")
    date_to = args.get("date_to")

    # Party filters imply emails.
    effective_type = type_
    if emitter_id or recipient_id:
        effective_type = "emails"

    cache_args = {
        "q": query, "type": effective_type, "limit": limit, "offset": offset,
        "collection": collection, "emitter": emitter_id, "recipient": recipient_id,
        "mentions": mentions_id, "date_from": date_from, "date_to": date_to,
    }
    ckey = store.cache_key("search", cache_args)
    cached = False
    data = None if no_cache else store.cache_get(ckey)
    if data is not None:
        cached = True
    else:
        params = _search_params(query, effective_type, limit, collection, offset)
        if emitter_id:
            params["filter:properties.emitters"] = emitter_id
        if recipient_id:
            params["filter:properties.recipients"] = recipient_id
        if mentions_id:
            params["filter:properties.mentions"] = mentions_id
        if date_from and date_to:
            params["filter:dates"] = f"{date_from}..{date_to}"
        elif date_from:
            params["filter:dates"] = f"{date_from}..*"
        elif date_to:
            params["filter:dates"] = f"*..{date_to}"
        # Property-filtered searches require schemata on Aleph Pro.
        if (emitter_id or recipient_id or mentions_id) and "filter:schemata" not in params:
            params["filter:schemata"] = "Email"
        data = client.get("/entities", params=params)
        store.cache_set(ckey, data)

    results = data.get("results") or []
    total = data.get("total", len(results))
    total_type = data.get("total_type", "eq")

    if sort_by_date:
        results.sort(key=lambda r: first_label((r.get("properties") or {}).get("date")))

    dropped = 0
    if effective_type == "emails":
        results, dropped = _dedupe_emails(results)

    server = client.server_name
    is_email_view = effective_type == "emails"
    rows: list[tuple] = []
    for entity in results:
        alias = see_entity(store, entity, server=server, collection_id=collection)
        rows.append(_email_row(alias, entity) if is_email_view
                    else _generic_row(alias, entity))
    headers = (["alias", "date", "from", "subject"] if is_email_view
               else ["alias", "date", "schema", "title"])

    shown_start = offset if not results else offset + 1
    shown_end = offset + len(results)
    query_label = f'"{query}"' if query else "(no text query)"
    total_str = f"{total}" + ("+" if total_type == "gte" else "")
    header = f"search {query_label} type={effective_type}  {total_str} hits, showing {shown_start}-{shown_end}"
    if emitter_id:
        header += f"  emitter={args.get('emitter')}"
    if recipient_id:
        header += f"  recipient={args.get('recipient')}"
    if mentions_id:
        header += f"  mentions={args.get('mentions')}"
    if date_from or date_to:
        header += f"  dates={date_from or '*'}..{date_to or '*'}"
    if sort_by_date:
        header += "  (sorted by date)"
    if collection:
        header += f"  collection={collection}"

    if not results:
        body = "(no results)"
    else:
        body = table(rows, headers=headers)
        if dropped > 0:
            body += f"\n\n[+{dropped} duplicate-subject emails collapsed]"
        if (offset + len(results)) < total:
            next_offset = offset + limit
            remaining = max(0, total - (offset + len(results)))
            tail = f"{remaining}" + ("+" if total_type == "gte" else "")
            body += f"\n[{tail} more hits — call search again with offset={next_offset}]"

    return envelope(header, body, cached=cached)


def cmd_read(client: AlephClient, store: Store, args: dict) -> str:
    alias = args.get("alias")
    if not alias:
        raise CommandError("read requires an alias", "pass alias=r1")
    full = bool(args.get("full"))
    raw = bool(args.get("raw"))
    eid = store.resolve_alias(alias)

    cached_from_graph = False
    if not raw and store.has_full_body(eid):
        props = store.cached_properties(eid)
        stub = store.get_entity(eid)
        if props is not None and stub is not None:
            data = {
                "id": eid,
                "schema": stub["schema"],
                "caption": stub["caption"],
                "properties": props,
            }
            cached_from_graph = True
        else:
            data = client.get(f"/entities/{eid}")
            see_entity(store, data, server=client.server_name, collection_id=None, full_body=True)
    else:
        data = client.get(f"/entities/{eid}")
        see_entity(store, data, server=client.server_name, collection_id=None, full_body=True)

    if raw:
        body = json.dumps(data, indent=2, ensure_ascii=False)
        return envelope(f"read {alias} --raw", body)

    props = data.get("properties") or {}
    schema = data.get("schema") or ""
    caption = data.get("caption") or ""
    body_text = first_label(props.get("bodyText")) or first_label(props.get("description"))
    if not full:
        body_text = truncate(body_text)

    out = [f"id:       {eid}", f"alias:    {alias}", f"schema:   {schema}"]
    if caption:
        out.append(f"caption:  {caption}")
    subject = first_label(props.get("subject"))
    if subject:
        out.append(f"subject:  {subject}")
    date = first_label(props.get("date"))
    if date:
        out.append(f"date:     {date}")

    for prop in REF_PROPERTIES:
        formatted = format_ftm_refs(store, props.get(prop))
        if formatted:
            out.append(f"{prop + ':':<9} {formatted}")

    raw_from = first_label(props.get("from"))
    if raw_from and not props.get("emitters"):
        out.append(f"from:     {raw_from}")
    raw_to = extract_label(props.get("to"))
    if raw_to and not props.get("recipients"):
        out.append(f"to:       {raw_to}")

    out.append(RULE)
    out.append(body_text or "(no body text)")

    header = f"read {alias}" + (" (from cache)" if cached_from_graph else "")
    return envelope(header, "\n".join(out))


def cmd_sources(client: AlephClient, store: Store, args: dict) -> str:
    limit = int(args.get("limit") or 50)
    grep = args.get("grep")
    data = client.get("/collections", params={"limit": limit})
    results = data.get("results") or []
    if grep:
        lower = grep.lower()
        results = [r for r in results if lower in (r.get("label") or "").lower()]
    if not results:
        return envelope("sources", "(none matching)")
    rows = [
        (str(r.get("id") or r.get("foreign_id") or ""),
         short(r.get("label") or "", 80),
         str(r.get("count", "")))
        for r in results
    ]
    header = "sources" + (f" --grep {grep}" if grep else "")
    return envelope(header, table(rows, headers=["id", "label", "count"]))


def cmd_hubs(client: AlephClient, store: Store, args: dict) -> str:
    query = (args.get("query") or "").strip()
    collection = args.get("collection")
    schema = args.get("schema") or "Email"
    top_n = max(1, min(25, int(args.get("limit") or 10)))

    api_params: dict[str, Any] = {
        "filter:schemata": schema,
        "limit": 0,
        "facet": [
            "properties.emitters",
            "properties.recipients",
            "properties.peopleMentioned",
            "properties.companiesMentioned",
        ],
        "facet_size:properties.emitters": top_n,
        "facet_size:properties.recipients": top_n,
        "facet_size:properties.peopleMentioned": top_n,
        "facet_size:properties.companiesMentioned": top_n,
    }
    if query:
        api_params["q"] = query
    if collection:
        api_params["filter:collection_id"] = collection

    cache_args = {"q": query, "schema": schema, "collection": collection, "topN": top_n}
    ckey = store.cache_key("hubs_facet", cache_args)
    cached = False
    data = store.cache_get(ckey)
    if data is not None:
        cached = True
    else:
        data = client.get("/entities", params=api_params)
        store.cache_set(ckey, data)

    total = data.get("total", 0)
    facets = data.get("facets") or {}
    server = client.server_name

    # Fetch any party entities we don't yet have a real cached blob for, so
    # facet rows can show readable names rather than ids.
    party_ids: set[str] = set()
    for key in ("properties.emitters", "properties.recipients"):
        f = facets.get(key) or {}
        for v in f.get("values") or []:
            i = v.get("id")
            if isinstance(i, str) and i:
                party_ids.add(i)
    to_fetch = []
    for pid in party_ids:
        stub = store.get_entity(pid)
        if not stub or (stub.get("schema") == "LegalEntity" and not stub.get("name")):
            to_fetch.append(pid)
    for pid in to_fetch:
        try:
            ent = client.get(f"/entities/{pid}")
            see_entity(store, ent, server=server, collection_id=collection)
        except CommandError:
            pass

    out: list[str] = []
    qlbl = f'"{query}"' if query else "(all)"
    out.append(f"{total} {schema.lower()} matches for {qlbl} in collection {collection or 'any'}")

    def render_entity_facet(title: str, facet_key: str) -> None:
        f = facets.get(facet_key) or {}
        values = f.get("values") or []
        if not values:
            return
        rows = []
        for v in values:
            i = v.get("id") or ""
            count = v.get("count") or 0
            if not i:
                continue
            stub = store.get_entity(i)
            if stub is None:
                store.remember(
                    eid=i, schema="LegalEntity", caption=None, name=None,
                    properties=None, collection_id=collection, server=server,
                )
                stub = store.get_entity(i)
            alias = store.assign_alias(i)
            display = (stub or {}).get("name") or (stub or {}).get("caption") or "(unnamed)"
            rows.append((alias, count, short(display, 80)))
        if rows:
            out.append("")
            out.append(f"## {title}")
            out.append(table(rows, headers=["alias", "count", "name"]))

    def render_string_facet(title: str, facet_key: str) -> None:
        f = facets.get(facet_key) or {}
        values = f.get("values") or []
        if not values:
            return
        rows = [(v.get("count") or 0, short(v.get("label") or v.get("id") or "?", 80))
                for v in values]
        out.append("")
        out.append(f"## {title}")
        out.append(table(rows, headers=["count", "label"]))

    render_entity_facet("Top senders (emitters)", "properties.emitters")
    render_entity_facet("Top recipients", "properties.recipients")
    render_string_facet("Top people mentioned", "properties.peopleMentioned")
    render_string_facet("Top companies mentioned", "properties.companiesMentioned")

    return envelope(f"hubs {qlbl}", "\n".join(out), cached=cached)


def cmd_similar(client: AlephClient, store: Store, args: dict) -> str:
    alias = args.get("alias")
    if not alias:
        raise CommandError("similar requires an alias", "pass alias=r5")
    limit = int(args.get("limit") or 10)
    eid = store.resolve_alias(alias)

    stub = store.get_entity(eid)
    if stub and stub["schema"] not in PARTY_SCHEMAS:
        raise CommandError(
            f"similar only supports party schemas — {alias} is a {stub['schema']}",
            "use expand instead for documents/emails/folders",
        )

    ckey = store.cache_key("similar", {"id": eid, "limit": limit})
    cached = False
    data = store.cache_get(ckey)
    if data is not None:
        cached = True
    else:
        data = client.get(f"/entities/{eid}/similar", params={"limit": limit})
        store.cache_set(ckey, data)

    results = data.get("results") or []
    total = data.get("total", len(results))
    if not results:
        return envelope(
            f"similar {alias}",
            "(no similar entities — this party is unique or isolated in its collection)",
        )

    server = client.server_name
    rows = []
    for row in results:
        entity = row.get("entity") or row
        score = row.get("score") or entity.get("score") or 0
        a = see_entity(store, entity, server=server, collection_id=None)
        sch = entity.get("schema") or ""
        props = entity.get("properties") or {}
        name_list = props.get("name") or []
        name = (name_list[0] if isinstance(name_list, list) and name_list
                else entity.get("caption") or "")
        coll = ((entity.get("collection") or {}).get("label")) or ""
        rows.append((a, f"{float(score):.1f}", sch, short(name, 60), short(coll, 40)))

    header = f"similar {alias} — {total} name-variant candidate(s)"
    return envelope(header,
                    table(rows, headers=["alias", "score", "schema", "name", "collection"]),
                    cached=cached)


def cmd_expand(client: AlephClient, store: Store, args: dict) -> str:
    alias = args.get("alias")
    if not alias:
        raise CommandError("expand requires an alias", "pass alias=r5")
    per_property = int(args.get("limit") or 20)
    prop_filter = args.get("property")
    no_cache = bool(args.get("no_cache"))
    eid = store.resolve_alias(alias)

    api_params: dict[str, Any] = {"limit": per_property}
    if prop_filter:
        api_params["filter:property"] = prop_filter

    ckey = store.cache_key("expand", {"id": eid, "property": prop_filter, "limit": per_property})
    cached = False
    data = None if no_cache else store.cache_get(ckey)
    if data is not None:
        cached = True
    else:
        data = client.get(f"/entities/{eid}/expand", params=api_params)
        store.cache_set(ckey, data)

    groups = data.get("results") or []

    stub = store.get_entity(eid)
    is_party = bool(stub and stub["schema"] in PARTY_SCHEMAS)
    total_in_groups = sum(len(g.get("entities") or []) for g in groups)
    if is_party and total_in_groups == 0:
        rows = [(g.get("property", "?"), g.get("count", 0)) for g in groups]
        body = ("expand on a party returns reverse-property counts only — use "
                "`search recipient=` / `emitter=` / `mentions=` to enumerate.\n\n"
                + table(rows, headers=["property", "count"]))
        return envelope(f"expand {alias}", body)

    if not groups:
        return envelope(f"expand {alias}", "(no related entities)")

    server = client.server_name
    out: list[str] = []
    total_seen = 0
    for group in sorted(groups, key=lambda g: g.get("count") or 0, reverse=True):
        prop = group.get("property") or "?"
        count = group.get("count") or 0
        entities = group.get("entities") or []
        if not entities:
            continue
        rows = []
        for e in entities:
            a = see_entity(store, e, server=server, collection_id=None)
            sch = e.get("schema") or ""
            props = e.get("properties") or {}
            n = (first_label(props.get("name"))
                 or first_label(props.get("subject"))
                 or e.get("caption") or "")
            d = first_label(props.get("date"))[:10]
            rows.append((a, sch, short(n, 70), d))
            total_seen += 1
        suffix = f", showing {len(entities)}" if len(entities) < count else ""
        out.append("")
        out.append(f"## {prop} ({count}{suffix})")
        out.append(table(rows, headers=["alias", "schema", "name", "date"]))

    header = f"expand {alias} — {total_seen} related across {len(groups)} properties"
    return envelope(header, "\n".join(out), cached=cached)


# ----- subtree scan, used by browse/tree --------------------------------


def _scan_subtree(
    client: AlephClient, store: Store, root_id: str,
    collection_id: str | None, max_entities: int,
) -> tuple[list[dict], int, bool]:
    """Paginate a `filter:properties.ancestors` scan. Returns (entities, total, hit_cap)."""
    page_limit = 200
    cache_args = {"root": root_id, "max": max_entities, "collection": collection_id or ""}
    ckey = store.cache_key("subtree_scan", cache_args)
    cached = store.cache_get(ckey)
    if cached:
        ents = cached.get("entities") or []
        for e in ents:
            see_entity(store, e, server=client.server_name, collection_id=collection_id)
        return ents, cached.get("total", len(ents)), bool(cached.get("hit_cap"))

    collected: list[dict] = []
    total = 0
    offset = 0
    hit_cap = False
    while True:
        params: dict[str, Any] = {
            "filter:properties.ancestors": root_id,
            "filter:schemata": TREE_DOC_SCHEMAS,
            "limit": page_limit,
            "offset": offset,
        }
        if collection_id:
            params["filter:collection_id"] = collection_id
        data = client.get("/entities", params=params)
        total = data.get("total", total)
        results = data.get("results") or []
        for e in results:
            see_entity(store, e, server=client.server_name, collection_id=collection_id)
            collected.append(e)
            if len(collected) >= max_entities:
                hit_cap = total > len(collected)
                store.cache_set(ckey, {"entities": collected, "total": total, "hit_cap": hit_cap})
                return collected, total, hit_cap
        if len(results) < page_limit:
            break
        offset += page_limit
        if offset >= 9800:
            hit_cap = True
            break
    if total > len(collected):
        hit_cap = True
    store.cache_set(ckey, {"entities": collected, "total": total, "hit_cap": hit_cap})
    return collected, total, hit_cap


def _entity_display_name(entity: dict) -> str:
    p = entity.get("properties") or {}
    for c in ("fileName", "title", "subject", "name"):
        v = first_label(p.get(c))
        if v:
            return v
    return entity.get("caption") or entity.get("id") or ""


def _count_descendants(eid: str, children_of: dict[str, list[dict]]) -> int:
    stack = [eid]
    visited = {eid}
    n = 0
    while stack:
        cur = stack.pop()
        for k in children_of.get(cur, []):
            kid = k.get("id")
            if not kid or kid in visited:
                continue
            visited.add(kid)
            n += 1
            stack.append(kid)
    return n


def cmd_browse(client: AlephClient, store: Store, args: dict) -> str:
    alias = args.get("alias")
    if not alias:
        raise CommandError("browse requires an alias", "pass alias=r5")
    limit = int(args.get("limit") or 30)
    eid = store.resolve_alias(alias)

    stub = store.get_entity(eid)
    target_props = store.cached_properties(eid) or {}
    schema = (stub or {}).get("schema") or ""
    is_folder = schema in FOLDER_SCHEMAS

    if is_folder:
        folder_id = eid
    else:
        parent_id = first_entity_ref_id(target_props.get("parent"))
        if not parent_id:
            fresh = client.get(f"/entities/{eid}")
            see_entity(store, fresh, server=client.server_name, collection_id=None, full_body=True)
            parent_id = first_entity_ref_id((fresh.get("properties") or {}).get("parent"))
            if not parent_id:
                return envelope(
                    f"browse {alias}",
                    "(no parent folder on record — this entity may be at the collection root)",
                )
            target_props = fresh.get("properties") or target_props
        folder_id = parent_id

    cid = store.collection_of(eid)
    entities, total_desc, hit_cap = _scan_subtree(
        client, store, folder_id, collection_id=cid, max_entities=1000,
    )

    children_of: dict[str, list[dict]] = {}
    for e in entities:
        pid = first_entity_ref_id((e.get("properties") or {}).get("parent"))
        if not pid:
            continue
        children_of.setdefault(pid, []).append(e)

    direct = children_of.get(folder_id, [])
    displayed = direct[:limit]
    truncated = len(direct) - len(displayed)

    sibling_rows = []
    for s in displayed:
        sid = s.get("id") or ""
        salias = store.alias_for(sid) or "-"
        sschema = s.get("schema") or ""
        sname = _entity_display_name(s)
        marker = "›" if sid == eid else ""
        contents = ""
        if sschema in FOLDER_SCHEMAS:
            kids_n = len(children_of.get(sid, []))
            if hit_cap and kids_n > 0:
                contents = f"{kids_n}+ desc"
            elif kids_n > 0:
                contents = f"{_count_descendants(sid, children_of)} desc"
            else:
                contents = "empty"
        sibling_rows.append((marker, salias, sschema, short(sname, 80), contents))

    breadcrumb = []
    ancestors = target_props.get("ancestors")
    aids = referenced_id_strings(ancestors)
    for aid in aids[:8]:
        a = store.alias_for(aid) or "-"
        st = store.get_entity(aid) or {}
        nm = st.get("name") or st.get("caption") or aid[:8]
        breadcrumb.append(f"{a} {nm}")

    folder_alias = store.alias_for(folder_id) or "-"
    folder_stub = store.get_entity(folder_id) or {}
    folder_name = folder_stub.get("name") or folder_stub.get("caption") or folder_id[:10]

    out: list[str] = []
    if breadcrumb:
        out.append("path: " + " / ".join(breadcrumb))
    out.append(f"folder: {folder_alias} {folder_name}")
    out.append("")
    if not sibling_rows:
        out.append("(no contents)")
    else:
        total_str = f"{total_desc}+" if hit_cap else f"{len(entities)}"
        out.append(f"contents (direct: {len(direct)}; subtree: {total_str}):")
        out.append(table(sibling_rows,
                         headers=["here", "alias", "schema", "name", "contents"]))
        if truncated > 0:
            out.append(f"… {truncated} more not shown — raise limit= to see them")
    if hit_cap:
        out.append("")
        out.append("warn: subtree larger than scan cap — descendant counts marked '+' are lower bounds")

    return envelope(f"browse {alias}", "\n".join(out))


def cmd_tree(client: AlephClient, store: Store, args: dict) -> str:
    alias = (args.get("alias") or "").strip()
    collection = (args.get("collection") or "").strip()
    depth = max(1, min(8, int(args.get("depth") or 3)))
    max_siblings = max(1, min(100, int(args.get("max_siblings") or 20)))

    if alias:
        return _tree_for_entity(client, store, alias, depth, max_siblings)
    if collection:
        return _tree_for_collection(client, store, collection, max_siblings)
    raise CommandError(
        "tree requires alias=<entity> or collection=<id>",
        "tree alias=r5  OR  tree collection=3843",
    )


def _tree_for_entity(client: AlephClient, store: Store, alias: str,
                     depth: int, max_siblings: int) -> str:
    eid = store.resolve_alias(alias)
    stub = store.get_entity(eid)
    schema = (stub or {}).get("schema") or ""
    if schema not in FOLDER_SCHEMAS:
        raise CommandError(
            f"tree only works on folder-like entities (Folder, Package, Workbook, Directory) — "
            f"{alias} is {schema or 'unknown'}",
            f"use browse {alias} to see siblings, or pass a folder alias",
        )
    cid = store.collection_of(eid)
    entities, total, hit_cap = _scan_subtree(
        client, store, eid, collection_id=cid, max_entities=5000,
    )
    root_alias = store.alias_for(eid) or alias
    root_name = (stub or {}).get("name") or (stub or {}).get("caption") or ""
    suffix = "+" if hit_cap else ""
    header = f"{root_alias}  {root_name}  [{schema}]  ({len(entities)} desc{suffix})"
    body = _render_subtree_ascii(store, eid, header, entities, hit_cap, depth, max_siblings)
    return envelope(f"tree {alias}", body)


def _tree_for_collection(client: AlephClient, store: Store, collection_id: str,
                         max_siblings: int) -> str:
    page_limit = 200
    roots: list[dict] = []
    offset = 0
    total = 0
    while len(roots) < max_siblings * 2:
        params: dict[str, Any] = {
            "filter:collection_id": collection_id,
            "empty:properties.parent": "true",
            "filter:schemata": TREE_DOC_SCHEMAS,
            "limit": page_limit,
            "offset": offset,
        }
        data = client.get("/entities", params=params)
        total = data.get("total", total)
        results = data.get("results") or []
        for e in results:
            see_entity(store, e, server=client.server_name, collection_id=collection_id)
            roots.append(e)
        if len(results) < page_limit:
            break
        offset += page_limit
        if offset >= 9800:
            break

    roots.sort(
        key=lambda r: (
            0 if (r.get("schema") or "") in FOLDER_SCHEMAS else 1,
            _entity_display_name(r).lower(),
        )
    )
    lines = [
        f"collection {collection_id}: {total} top-level entr{'y' if total == 1 else 'ies'}",
        "",
    ]
    displayed = roots[:max_siblings]
    for i, r in enumerate(displayed):
        last = (i == len(displayed) - 1) and (len(roots) <= max_siblings)
        branch = "└── " if last else "├── "
        rid = r.get("id") or ""
        ralias = store.alias_for(rid) or "-"
        rsch = r.get("schema") or "?"
        rname = _entity_display_name(r)
        lines.append(f"{branch}{ralias:<5}  {rsch:<10}  {short(rname, 60)}")
    hidden = max(0, total - len(displayed))
    if hidden > 0:
        lines.append(f"└── … {hidden} more roots not listed — raise max_siblings or use tree alias=…")
    if total >= 10000:
        lines.append("")
        lines.append("warn: collection has >= 10000 top-level entries (Aleph cap) — true count may be higher")
    return envelope(f"tree collection={collection_id}", "\n".join(lines))


def _render_subtree_ascii(
    store: Store, root_id: str, header: str,
    entities: list[dict], hit_cap: bool, depth: int, max_siblings: int,
) -> str:
    children_of: dict[str, list[dict]] = {}
    for e in entities:
        pid = first_entity_ref_id((e.get("properties") or {}).get("parent"))
        if pid:
            children_of.setdefault(pid, []).append(e)
    for k in children_of:
        children_of[k].sort(
            key=lambda r: (
                0 if (r.get("schema") or "") in FOLDER_SCHEMAS else 1,
                _entity_display_name(r).lower(),
            )
        )

    lines = [header]

    def walk(eid: str, prefix: str, current_depth: int) -> None:
        kids = children_of.get(eid, [])
        displayed = kids[:max_siblings]
        trunc = len(kids) - len(displayed)
        for i, k in enumerate(displayed):
            last = (i == len(displayed) - 1) and (trunc == 0)
            branch = "└── " if last else "├── "
            kid = k.get("id") or ""
            kalias = store.alias_for(kid) or "-"
            ksch = k.get("schema") or "?"
            kname = _entity_display_name(k)
            is_folder = ksch in FOLDER_SCHEMAS
            ann = ""
            if is_folder:
                direct = len(children_of.get(kid, []))
                ann = f"  ({direct})" if direct > 0 else "  (empty)"
            lines.append(
                f"{prefix}{branch}{kalias:<5} {short(kname, 56)} [{ksch}]{ann}"
            )
            if is_folder and current_depth + 1 < depth:
                next_prefix = prefix + ("    " if last else "│   ")
                walk(kid, next_prefix, current_depth + 1)
            elif is_folder and current_depth + 1 == depth:
                if children_of.get(kid):
                    next_prefix = prefix + ("    " if last else "│   ")
                    lines.append(f"{next_prefix}└── … (depth limit; raise depth to see)")
        if trunc > 0:
            lines.append(f"{prefix}└── … {trunc} more entries not shown — raise max_siblings")

    walk(root_id, "", 1)
    if hit_cap:
        lines.append("")
        lines.append("warn: subtree exceeds scan cap — counts and deep branches may be incomplete")
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Local-only commands — read against the cache DB without hitting Aleph.
# ---------------------------------------------------------------------------


def _label_for(store: Store, eid: str) -> tuple[str, str, str]:
    """Return (alias_or_dash, schema_or_dash, display_name) for an entity id
    we may or may not have ingested yet."""
    alias = store.alias_for(eid) or "-"
    stub = store.get_entity(eid) or {}
    schema = stub.get("schema") or "?"
    name = stub.get("name") or stub.get("caption") or eid[:10]
    return alias, schema, name


def cmd_neighbors(store: Store, args: dict) -> str:
    """Show every cached edge touching an entity, grouped by property.
    No round-trip — pure local lookup against the edges table."""
    alias = args.get("alias")
    if not alias:
        raise CommandError("neighbors requires an alias", "pass alias=r5")
    direction = (args.get("direction") or "both").lower()
    if direction not in ("out", "in", "both"):
        raise CommandError(
            f"unknown direction '{direction}'",
            "use direction=out, direction=in, or direction=both",
        )
    prop_filter = args.get("property")
    limit = max(1, int(args.get("limit") or 50))

    eid = store.resolve_alias(alias)
    self_alias, self_schema, self_name = _label_for(store, eid)

    out: list[str] = [f"{self_alias} {self_schema}  {short(self_name, 60)}"]

    def render_block(title: str, rows: list[tuple], headers: list[str]) -> None:
        if not rows:
            return
        out.append("")
        out.append(f"## {title}")
        out.append(table(rows, headers=headers))

    if direction in ("out", "both"):
        sql = ("SELECT prop, dst_id FROM edges WHERE src_id=?"
               + (" AND prop=?" if prop_filter else "")
               + " ORDER BY prop, dst_id")
        params: tuple = (eid, prop_filter) if prop_filter else (eid,)
        rows = []
        truncated = 0
        per_prop: dict[str, int] = {}
        for r in store.conn.execute(sql, params):
            prop = r["prop"]
            per_prop[prop] = per_prop.get(prop, 0) + 1
            if per_prop[prop] > limit:
                truncated += 1
                continue
            a, sch, nm = _label_for(store, r["dst_id"])
            rows.append((prop, a, sch, short(nm, 60)))
        render_block(f"out edges ({len(rows)})", rows,
                     ["property", "alias", "schema", "name"])
        if truncated:
            out.append(f"… {truncated} edges hidden (raise limit=)")

    if direction in ("in", "both"):
        sql = ("SELECT prop, src_id FROM edges WHERE dst_id=?"
               + (" AND prop=?" if prop_filter else "")
               + " ORDER BY prop, src_id")
        params = (eid, prop_filter) if prop_filter else (eid,)
        rows = []
        truncated = 0
        per_prop = {}
        for r in store.conn.execute(sql, params):
            prop = r["prop"]
            per_prop[prop] = per_prop.get(prop, 0) + 1
            if per_prop[prop] > limit:
                truncated += 1
                continue
            a, sch, nm = _label_for(store, r["src_id"])
            rows.append((prop, a, sch, short(nm, 60)))
        render_block(f"in edges ({len(rows)})", rows,
                     ["property", "alias", "schema", "name"])
        if truncated:
            out.append(f"… {truncated} edges hidden (raise limit=)")

    if len(out) == 1:
        out.append("")
        out.append("(no cached edges — the entity may not have been expanded yet; "
                   "try `expand` or `read` first)")

    header = f"neighbors {alias}"
    if prop_filter:
        header += f" property={prop_filter}"
    if direction != "both":
        header += f" direction={direction}"
    return envelope(header, "\n".join(out))


def cmd_recall(store: Store, args: dict) -> str:
    """Summarise what's already in the local cache: schema mix, top-degree
    nodes, most-recently-touched entities. Useful at session start to
    answer 'what do I already know?' without round-tripping Aleph."""
    collection = args.get("collection")
    schema_filter = args.get("schema")
    limit = max(1, min(50, int(args.get("limit") or 15)))

    where: list[str] = []
    params: list[Any] = []
    if collection:
        where.append("collection_id=?")
        params.append(collection)
    if schema_filter:
        where.append("schema=?")
        params.append(schema_filter)
    where_sql = (" WHERE " + " AND ".join(where)) if where else ""

    total = store.conn.execute(
        f"SELECT COUNT(*) FROM entities{where_sql}", params
    ).fetchone()[0]
    full_bodies = store.conn.execute(
        f"SELECT COUNT(*) FROM entities{where_sql + (' AND' if where else ' WHERE')} has_full_body=1",
        params,
    ).fetchone()[0]
    edge_count = store.conn.execute("SELECT COUNT(*) FROM edges").fetchone()[0]

    out: list[str] = []
    scope = []
    if collection:
        scope.append(f"collection={collection}")
    if schema_filter:
        scope.append(f"schema={schema_filter}")
    scope_label = "  ".join(scope) if scope else "all"
    out.append(f"{total} entities ({full_bodies} with full body), "
               f"{edge_count} cached edges  [{scope_label}]")

    schema_rows = store.conn.execute(
        f"SELECT schema, COUNT(*) AS n FROM entities{where_sql} "
        f"GROUP BY schema ORDER BY n DESC LIMIT {limit}",
        params,
    ).fetchall()
    if schema_rows:
        out.append("")
        out.append("## by schema")
        out.append(table([(r["schema"], r["n"]) for r in schema_rows],
                         headers=["schema", "count"]))

    # Top-degree nodes (sum of in + out edges). Restrict to entities we
    # have stubs for so we can show readable names.
    degree_sql = """
        SELECT e.id AS id, e.schema AS schema, e.name AS name, e.caption AS caption,
               COALESCE(o.n, 0) + COALESCE(i.n, 0) AS degree
          FROM entities e
          LEFT JOIN (SELECT src_id AS id, COUNT(*) AS n FROM edges GROUP BY src_id) o
                 ON o.id = e.id
          LEFT JOIN (SELECT dst_id AS id, COUNT(*) AS n FROM edges GROUP BY dst_id) i
                 ON i.id = e.id
    """
    if where:
        degree_sql += " WHERE " + " AND ".join(f"e.{w}" for w in where)
    degree_sql += f" ORDER BY degree DESC, e.updated_at DESC LIMIT {limit}"
    degree_rows = store.conn.execute(degree_sql, params).fetchall()
    deg_rows: list[tuple] = []
    for r in degree_rows:
        if not r["degree"]:
            continue
        a = store.alias_for(r["id"]) or "-"
        nm = r["name"] or r["caption"] or r["id"][:10]
        deg_rows.append((a, r["schema"] or "?", short(nm, 50), r["degree"]))
    if deg_rows:
        out.append("")
        out.append("## top by degree (in+out edges)")
        out.append(table(deg_rows, headers=["alias", "schema", "name", "degree"]))

    recent_sql = (
        f"SELECT id, schema, name, caption, updated_at FROM entities{where_sql} "
        f"ORDER BY updated_at DESC LIMIT {limit}"
    )
    recent = store.conn.execute(recent_sql, params).fetchall()
    rec_rows: list[tuple] = []
    for r in recent:
        a = store.alias_for(r["id"]) or "-"
        nm = r["name"] or r["caption"] or r["id"][:10]
        rec_rows.append((a, r["schema"] or "?", short(nm, 50),
                         (r["updated_at"] or "")[:19]))
    if rec_rows:
        out.append("")
        out.append("## recently touched")
        out.append(table(rec_rows, headers=["alias", "schema", "name", "updated"]))

    return envelope("recall " + scope_label, "\n".join(out))


def cmd_cache_stats(store: Store, args: dict) -> str:
    """Visibility into the response cache: size, age, hit-shape."""
    db_path = store.db_path
    size_bytes = db_path.stat().st_size if db_path.exists() else 0

    counts = {
        "entities": store.conn.execute("SELECT COUNT(*) FROM entities").fetchone()[0],
        "aliases": store.conn.execute("SELECT COUNT(*) FROM aliases").fetchone()[0],
        "edges": store.conn.execute("SELECT COUNT(*) FROM edges").fetchone()[0],
        "cache": store.conn.execute("SELECT COUNT(*) FROM cache").fetchone()[0],
    }
    full_bodies = store.conn.execute(
        "SELECT COUNT(*) FROM entities WHERE has_full_body=1"
    ).fetchone()[0]

    cache_age = store.conn.execute(
        "SELECT MIN(set_at), MAX(set_at) FROM cache"
    ).fetchone()
    oldest = cache_age[0] if cache_age else None
    newest = cache_age[1] if cache_age else None

    def fmt_size(n: int) -> str:
        for unit in ("B", "KB", "MB", "GB"):
            if n < 1024:
                return f"{n:.1f} {unit}"
            n /= 1024  # type: ignore[assignment]
        return f"{n:.1f} TB"

    rows = [
        ("db", str(db_path)),
        ("size", fmt_size(size_bytes)),
        ("entities", f"{counts['entities']} ({full_bodies} with full body)"),
        ("aliases", str(counts["aliases"])),
        ("edges", str(counts["edges"])),
        ("cached responses", str(counts["cache"])),
        ("oldest cache entry", oldest or "(empty)"),
        ("newest cache entry", newest or "(empty)"),
    ]
    return envelope("cache stats", table(rows, headers=["key", "value"]))


def cmd_cache_clear(store: Store, args: dict) -> str:
    """Truncate the response cache. Entities, aliases, and edges are
    preserved — only the keyed-response table is cleared, so the agent
    will refetch on the next call but keep its graph and aliases."""
    older_than_days = args.get("older_than_days")
    if older_than_days is not None:
        try:
            days = int(older_than_days)
        except (TypeError, ValueError) as exc:
            raise CommandError(
                f"older_than_days must be an integer, got {older_than_days!r}"
            ) from exc
        cutoff = (datetime.now(timezone.utc) - timedelta(days=days)).strftime(
            "%Y-%m-%dT%H:%M:%SZ"
        )
        cur = store.conn.execute("DELETE FROM cache WHERE set_at < ?", (cutoff,))
        scope = f"older than {days}d (cutoff {cutoff})"
    else:
        cur = store.conn.execute("DELETE FROM cache")
        scope = "all entries"
    deleted = cur.rowcount
    store.conn.commit()
    body = f"cleared {deleted} cache entr{'y' if deleted == 1 else 'ies'} ({scope})"
    return envelope("cache clear", body)


# ---------------------------------------------------------------------------
# Read-only SQL passthrough.
# ---------------------------------------------------------------------------

SQL_MAX_ROWS = 100


def cmd_sql(store: Store, args: dict) -> str:
    """Run an arbitrary read-only SELECT against the cache DB. Opens a
    fresh connection in mode=ro so writes can't slip through, regardless
    of the query text. Result is rendered as a table; long results are
    truncated to SQL_MAX_ROWS with a hint to add LIMIT."""
    query = args.get("query")
    if not query:
        raise CommandError(
            "sql requires a query",
            'pass query="select alias, n from aliases order by n desc limit 5"',
        )
    query = query.strip()

    uri = f"file:{store.db_path}?mode=ro"
    ro = sqlite3.connect(uri, uri=True)
    ro.row_factory = sqlite3.Row
    try:
        try:
            cur = ro.execute(query)
        except sqlite3.Error as exc:
            raise CommandError(f"sqlite error: {exc}",
                               "see SKILL.md for the cache schema") from exc
        if cur.description is None:
            return envelope("sql", "(query produced no result set)")
        headers = [d[0] for d in cur.description]
        rows: list[tuple] = []
        truncated = 0
        for i, r in enumerate(cur):
            if i >= SQL_MAX_ROWS:
                truncated += 1
                continue
            rows.append(tuple("" if v is None else short(str(v), 80) for v in r))
        truncated += sum(1 for _ in cur)  # exhaust any remainder
    finally:
        ro.close()

    if not rows:
        body = f"(0 rows)\ncolumns: {', '.join(headers)}"
    else:
        body = table(rows, headers=headers) + f"\n\n{len(rows)} row(s)"
        if truncated:
            body += (f"\n[+{truncated} more rows truncated — "
                     f"add LIMIT to your query to scope the result]")
    return envelope("sql", body)
