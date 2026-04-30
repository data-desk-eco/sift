"""Research-tool implementations: search, read, sources, hubs, similar,
expand, browse, tree. Each command takes (client, store, args) and
returns a formatted envelope string. Cohesive enough to keep in one
file — the cmd_* functions all share the cache-key / call / render
shape, and they share the small subtree/format helpers below."""

from __future__ import annotations

import json
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


def _format_email_hit(alias: str, entity: dict) -> str:
    props = entity.get("properties") or {}
    date = first_label(props.get("date"))[:10] or ""
    sender_raw = first_label(props.get("from")) or "unknown"
    sender = strip_email_address(sender_raw)
    subject = first_label(props.get("subject")) or entity.get("title") or "(no subject)"
    return f"{alias:<5} {date:<10}  {short(sender, 22):<22}  {short(subject, 60)}"


def _format_generic_hit(alias: str, entity: dict) -> str:
    props = entity.get("properties") or {}
    schema = entity.get("schema") or ""
    title = (
        first_label(props.get("title"))
        or first_label(props.get("name"))
        or first_label(props.get("fileName"))
        or entity.get("title")
        or entity.get("name")
        or "(untitled)"
    )
    date = (first_label(props.get("date")) or first_label(props.get("createdAt")))[:10]
    return f"{alias:<5} {date:<10}  {schema:<14}  {short(title, 56)}"


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
    lines: list[str] = []
    for entity in results:
        alias = see_entity(store, entity, server=server, collection_id=collection)
        if effective_type == "emails" or entity.get("schema") == "Email":
            lines.append(_format_email_hit(alias, entity))
        else:
            lines.append(_format_generic_hit(alias, entity))
    if dropped > 0:
        lines.append(f"      [+{dropped} duplicate-subject emails collapsed]")

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

    has_more = (offset + len(results)) < total
    next_acts: list[str] = []
    if not results:
        body = "(no results)"
        next_acts = [
            f'search query="{query}" type=docs',
            f'hubs query="{query}"',
        ]
    else:
        body = "\n".join(lines)
        first_alias = store.alias_for(results[0]["id"]) or "r1"
        next_acts = [
            f"read alias={first_alias}",
            f"browse alias={first_alias}",
            f'note kind=finding alias={first_alias} text="…"  (judge after reading)',
        ]
        if has_more:
            next_offset = offset + limit
            remaining = max(0, total - (offset + len(results)))
            next_acts.insert(
                0,
                f'search query="{query}" type={effective_type} offset={next_offset}  (page forward)',
            )
            tail = f"{remaining}" + ("+" if total_type == "gte" else "")
            body += f"\n      [{tail} more hits available — call search again with offset={next_offset}]"

    return envelope(header, body, next_actions=next_acts, cached=cached)


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
    return envelope(
        header,
        "\n".join(out),
        next_actions=[
            f"browse alias={alias}  (siblings in same folder)",
            f"expand alias={alias}  (all FtM refs grouped)",
        ],
    )


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
    lines = []
    for r in results:
        cid = r.get("id") or r.get("foreign_id") or ""
        label = r.get("label") or ""
        count = str(r.get("count", ""))
        lines.append(f"{str(cid):<8}  {short(label, 66):<66}  {count}")
    header = "sources" + (f" --grep {grep}" if grep else "")
    return envelope(
        header, "\n".join(lines),
        next_actions=['search query="<term>" collection=<id>'],
    )


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
    out.append("")

    sentence_caches: list[str] = []

    def render_entity_facet(title: str, facet_key: str) -> None:
        f = facets.get(facet_key) or {}
        values = f.get("values") or []
        if not values:
            return
        out.append(f"## {title}")
        for v in values:
            i = v.get("id") or ""
            count = v.get("count") or 0
            if not i:
                continue
            stub = store.get_entity(i)
            if stub is None:
                # Cache a placeholder so the alias still works.
                store.remember(
                    eid=i, schema="LegalEntity", caption=None, name=None,
                    properties=None, collection_id=collection, server=server,
                )
                stub = store.get_entity(i)
            alias = store.assign_alias(i)
            display = (stub or {}).get("name") or (stub or {}).get("caption") or "(unnamed)"
            out.append(f"  {alias:<5} {count:<5}  {short(display, 60)}")
        out.append("")

    def render_string_facet(title: str, facet_key: str) -> None:
        f = facets.get(facet_key) or {}
        values = f.get("values") or []
        if not values:
            return
        out.append(f"## {title} — use as search terms")
        for v in values:
            label = v.get("label") or v.get("id") or "?"
            count = v.get("count") or 0
            out.append(f'  {count:<5}  "{short(label, 66)}"')
            sentence_caches.append(label)
        out.append("")

    render_entity_facet("Top senders (emitters)", "properties.emitters")
    render_entity_facet("Top recipients", "properties.recipients")
    render_string_facet("Top people mentioned", "properties.peopleMentioned")
    render_string_facet("Top companies mentioned", "properties.companiesMentioned")

    next_acts = [
        "read alias=<first promising hit>",
        f'search query="{sentence_caches[0] if sentence_caches else "<new term>"}"'
        + (f" collection={collection}" if collection else ""),
        "expand alias=<hub alias>",
    ]
    return envelope(f"hubs {qlbl}", "\n".join(out), next_actions=next_acts, cached=cached)


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
    lines = []
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
        lines.append(
            f"{a:<5} {score:<6.1f}  {sch:<14}  "
            f"{short(name, 40):<40}  {short(coll, 28)}"
        )

    header = (f"similar {alias}" + ("  (cached)" if cached else "")
              + f"  —  {total} name-variant candidate(s)")
    body = (
        "alias  score   schema          name                                      collection\n"
        + ("-" * 100) + "\n" + "\n".join(lines)
    )
    return envelope(
        header, body,
        next_actions=[
            "read alias=<alias>  (inspect a candidate)",
        ],
    )


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
        hint = ["(expand on a party returns reverse-property counts only — use search with filters)"]
        for g in groups:
            hint.append(f"  {g.get('property', '?')}: {g.get('count', 0)}")
        return envelope(
            f"expand {alias}",
            "\n".join(hint),
            next_actions=[
                f"search recipient={alias} limit=20",
                f"search emitter={alias} limit=20",
                f"similar alias={alias}",
            ],
        )

    if not groups:
        return envelope(
            f"expand {alias}", "(no related entities)",
            next_actions=[f"read alias={alias}"],
        )

    server = client.server_name
    out: list[str] = []
    total_seen = 0
    sorted_groups = sorted(groups, key=lambda g: g.get("count") or 0, reverse=True)
    for group in sorted_groups:
        prop = group.get("property") or "?"
        count = group.get("count") or 0
        entities = group.get("entities") or []
        if not entities:
            continue
        out.append("")
        suffix = f", showing {len(entities)}" if len(entities) < count else ""
        out.append(f"— {prop} ({count}{suffix}):")
        for e in entities:
            a = see_entity(store, e, server=server, collection_id=None)
            sch = e.get("schema") or ""
            cap = e.get("caption") or ""
            props = e.get("properties") or {}
            n = (first_label(props.get("name"))
                 or first_label(props.get("subject"))
                 or cap)
            d = first_label(props.get("date"))[:10]
            datepart = f" {d}" if d else ""
            out.append(f"  {a:<5}  {sch:<12}  {short(n, 50)}{datepart}")
            total_seen += 1

    header = (f"expand {alias}" + ("  (cached)" if cached else "")
              + f"  —  {total_seen} related across {len(groups)} properties")
    return envelope(
        header, "\n".join(out),
        next_actions=[
            "read alias=<a>",
            f"expand alias={alias} property=<property-name>  (narrow to one group)",
        ],
    )


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

    sibling_lines = []
    for s in displayed:
        sid = s.get("id") or ""
        salias = store.alias_for(sid) or "-"
        sschema = s.get("schema") or ""
        sname = _entity_display_name(s)
        marker = "›" if sid == eid else " "
        ann = ""
        if sschema in FOLDER_SCHEMAS:
            kids_n = len(children_of.get(sid, []))
            if hit_cap and kids_n > 0:
                ann = f"  ({kids_n}+ desc)"
            elif kids_n > 0:
                ann = f"  ({_count_descendants(sid, children_of)} desc)"
            else:
                ann = "  (empty)"
        sibling_lines.append(
            f"  {marker} {salias:<5}  {sschema:<10}  {short(sname, 60)}{ann}"
        )
    if truncated > 0:
        sibling_lines.append(f"  … {truncated} more not shown — raise `limit` to see them")

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
    if not sibling_lines:
        out.append("(no contents)")
    else:
        total_str = f"{total_desc}+" if hit_cap else f"{len(entities)}"
        out.append(f"contents of this folder (direct: {len(direct)}; subtree: {total_str}):")
        out.extend(sibling_lines)
    if hit_cap:
        out.append("")
        out.append("warn: subtree larger than scan cap — descendant counts marked '+' are lower bounds")

    return envelope(
        f"browse {alias}", "\n".join(out),
        next_actions=[
            "read alias=<a>",
            f"tree alias={folder_alias}  (full subtree shape)",
            f"browse alias={folder_alias}  (up into parent folder)",
        ],
    )


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
    return envelope(
        f"tree {alias}", body,
        next_actions=[
            "tree alias=<sub-folder-alias>  (drill in)",
            "browse alias=<a>", "read alias=<a>",
        ],
    )


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
    return envelope(
        f"tree collection={collection_id}", "\n".join(lines),
        next_actions=["tree alias=<r-alias>", "browse alias=<r-alias>"],
    )


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
