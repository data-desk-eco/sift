import Foundation

/// Recursively cache an Aleph entity blob, assign it a stable alias,
/// and walk its nested entity refs (emitters, recipients, mentions,
/// parent, …) so they all get aliases without round-trips. Free
/// function rather than a method on `Store` because the recursion
/// needs a `seen` set passed by reference.
@discardableResult
public func seeEntity(
    store: Store,
    entity: [String: Any],
    server: String?,
    collectionId: String?,
    fullBody: Bool = false,
    seen: inout Set<String>
) throws -> String {
    guard let eid = entity["id"] as? String, !eid.isEmpty else { return "" }
    if seen.contains(eid) {
        return (try store.aliasFor(eid)) ?? ""
    }

    let schema = (entity["schema"] as? String) ?? "Thing"
    let caption = entity["caption"] as? String
    let props = (entity["properties"] as? [String: Any]) ?? [:]
    let name = Render.firstString(props["name"])
        ?? Render.firstString(props["title"])
        ?? Render.firstString(props["subject"])
        ?? caption
        ?? Render.firstString(props["fileName"])

    var cid = collectionId
    if let coll = entity["collection"] as? [String: Any] {
        cid = (coll["collection_id"] as? String)
            ?? (coll["foreign_id"] as? String)
            ?? (coll["id"] as? String)
            ?? cid
    } else if let direct = entity["collection_id"] as? String {
        cid = direct
    }

    try store.remember(
        eid: eid,
        schema: schema,
        caption: caption,
        name: name,
        properties: props.isEmpty ? nil : props,
        collectionId: cid,
        server: server,
        fullBody: fullBody
    )
    try store.recordEdges(srcId: eid, properties: props)
    let alias = try store.assignAlias(eid)

    seen.insert(eid)
    for value in props.values {
        try recurseInto(store: store, value: value, server: server, collectionId: cid, seen: &seen)
    }
    return alias
}

/// Convenience overload — manage the visited set for the caller.
@discardableResult
public func seeEntity(
    store: Store,
    entity: [String: Any],
    server: String?,
    collectionId: String?,
    fullBody: Bool = false
) throws -> String {
    var seen: Set<String> = []
    return try seeEntity(
        store: store, entity: entity,
        server: server, collectionId: collectionId,
        fullBody: fullBody, seen: &seen
    )
}

private func recurseInto(
    store: Store,
    value: Any?,
    server: String?,
    collectionId: String?,
    seen: inout Set<String>
) throws {
    switch value {
    case let dict as [String: Any]:
        if let eid = dict["id"] as? String, !eid.isEmpty,
           let _ = dict["schema"] as? String {
            try seeEntity(
                store: store, entity: dict,
                server: server, collectionId: collectionId,
                fullBody: false, seen: &seen
            )
        }
    case let arr as [Any]:
        for item in arr {
            try recurseInto(
                store: store, value: item,
                server: server, collectionId: collectionId, seen: &seen
            )
        }
    default:
        return
    }
}

/// Format a list-of-FtM-entity-refs property (e.g. `emitters`,
/// `recipients`) for the `read` envelope. Falls back to short ids for
/// bare-string refs we haven't ingested.
public func formatFtmRefs(store: Store, value: Any?) throws -> String {
    guard let value, !(value is NSNull) else { return "" }
    var items: [(alias: String, display: String)] = []

    func add(_ d: [String: Any]) throws {
        guard let eid = d["id"] as? String, !eid.isEmpty else { return }
        let alias = (try store.aliasFor(eid)) ?? "?"
        let props = (d["properties"] as? [String: Any]) ?? [:]
        let display: String
        if let names = props["name"] as? [Any], let first = names.first {
            display = Render.extractLabel(first)
        } else if let caption = d["caption"] as? String, !caption.isEmpty {
            display = caption
        } else if let email = Render.firstString(props["email"]) {
            display = email
        } else {
            display = String(eid.prefix(10))
        }
        items.append((alias, display))
    }

    if let dict = value as? [String: Any] {
        try add(dict)
    } else if let arr = value as? [Any] {
        for item in arr {
            if let dict = item as? [String: Any] {
                try add(dict)
            } else if let s = item as? String {
                let alias = (try store.aliasFor(s)) ?? "?"
                let stub = try store.getEntity(s)
                let display = stub?.name ?? stub?.caption ?? String(s.prefix(10))
                items.append((alias, display))
            }
        }
    }

    return items
        .map { "\($0.alias) \(Render.short($0.display, width: 28))" }
        .joined(separator: ", ")
}
