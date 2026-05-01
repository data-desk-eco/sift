import Foundation

public struct TreeInput: Sendable {
    public var alias: String?
    public var collection: String?
    public var depth: Int
    public var maxSiblings: Int
    public init(
        alias: String? = nil, collection: String? = nil,
        depth: Int = 3, maxSiblings: Int = 20
    ) {
        self.alias = alias; self.collection = collection
        self.depth = max(1, min(8, depth))
        self.maxSiblings = max(1, min(100, maxSiblings))
    }
}

public func runTree(
    client: AlephClient, store: Store, input: TreeInput
) async throws -> String {
    if let alias = input.alias?.trimmingCharacters(in: .whitespaces),
       !alias.isEmpty {
        return try await treeForEntity(
            client: client, store: store,
            alias: alias, depth: input.depth, maxSiblings: input.maxSiblings
        )
    }
    if let c = input.collection?.trimmingCharacters(in: .whitespaces), !c.isEmpty {
        return try await treeForCollection(
            client: client, store: store,
            collectionId: c, maxSiblings: input.maxSiblings
        )
    }
    throw SiftError(
        "tree requires an entity alias positional or --collection <id>",
        suggestion: "sift tree r5  OR  sift tree --collection 3843"
    )
}

private func treeForEntity(
    client: AlephClient, store: Store,
    alias: String, depth: Int, maxSiblings: Int
) async throws -> String {
    let eid = try store.resolveAlias(alias)
    let stub = try store.getEntity(eid)
    let schema = stub?.schema ?? ""
    if !Schemas.folderSchemas.contains(schema) {
        throw SiftError(
            "tree only works on folder-like entities (Folder, Package, Workbook, Directory) — \(alias) is \(schema.isEmpty ? "unknown" : schema)",
            suggestion: "sift browse \(alias) to see siblings, or pass a folder alias"
        )
    }
    let cid = try store.collectionOf(eid)
    let scan = try await scanSubtree(
        client: client, store: store,
        rootId: eid, collectionId: cid, maxEntities: 5000
    )
    let rootAlias = (try store.aliasFor(eid)) ?? alias
    let rootName = stub?.name ?? stub?.caption ?? ""
    let suffix = scan.hitCap ? "+" : ""
    let header = "\(rootAlias)  \(rootName)  [\(schema)]  (\(scan.entities.count) desc\(suffix))"
    let body = renderSubtreeAscii(
        store: store, rootId: eid, header: header,
        entities: scan.entities, hitCap: scan.hitCap,
        depth: depth, maxSiblings: maxSiblings
    )
    return Render.envelope("tree \(alias)", body)
}

private func treeForCollection(
    client: AlephClient, store: Store,
    collectionId: String, maxSiblings: Int
) async throws -> String {
    let pageLimit = 200
    var roots: [[String: Any]] = []
    var offset = 0
    var total = 0
    while roots.count < maxSiblings * 2 {
        let params: [String: Any] = [
            "filter:collection_id": collectionId,
            "empty:properties.parent": "true",
            "filter:schemata": Schemas.treeDocSchemas,
            "limit": pageLimit, "offset": offset,
        ]
        let data = try await client.get("/entities", params: params)
        total = (data["total"] as? Int) ?? total
        let results = (data["results"] as? [[String: Any]]) ?? []
        let serverName = client.serverName
        for e in results {
            try seeEntity(
                store: store, entity: e,
                server: serverName, collectionId: collectionId
            )
            roots.append(e)
        }
        if results.count < pageLimit { break }
        offset += pageLimit
        if offset >= 9800 { break }
    }
    roots.sort { lhs, rhs in
        let la = Schemas.folderSchemas.contains(lhs["schema"] as? String ?? "") ? 0 : 1
        let ra = Schemas.folderSchemas.contains(rhs["schema"] as? String ?? "") ? 0 : 1
        if la != ra { return la < ra }
        return entityDisplayName(lhs).lowercased() < entityDisplayName(rhs).lowercased()
    }
    var lines: [String] = [
        "collection \(collectionId): \(total) top-level entr\(total == 1 ? "y" : "ies")",
        "",
    ]
    let displayed = Array(roots.prefix(maxSiblings))
    for (i, r) in displayed.enumerated() {
        let last = (i == displayed.count - 1) && (roots.count <= maxSiblings)
        let branch = last ? "└── " : "├── "
        let rid = (r["id"] as? String) ?? ""
        let ralias = (try store.aliasFor(rid)) ?? "-"
        let rsch = (r["schema"] as? String) ?? "?"
        let rname = entityDisplayName(r)
        lines.append("\(branch)\(pad(ralias, to: 5))  \(pad(rsch, to: 10))  \(Render.short(rname, width: 60))")
    }
    let hidden = max(0, total - displayed.count)
    if hidden > 0 {
        lines.append("└── … \(hidden) more roots not listed — raise --max-siblings or use sift tree <alias>")
    }
    if total >= 10000 {
        lines.append("")
        lines.append("warn: collection has >= 10000 top-level entries (Aleph cap) — true count may be higher")
    }
    return Render.envelope("tree --collection \(collectionId)", lines.joined(separator: "\n"))
}

private func renderSubtreeAscii(
    store: Store, rootId: String, header: String,
    entities: [[String: Any]], hitCap: Bool,
    depth: Int, maxSiblings: Int
) -> String {
    var childrenOf: [String: [[String: Any]]] = [:]
    for e in entities {
        let props = (e["properties"] as? [String: Any]) ?? [:]
        if let pid = Render.firstEntityRefId(props["parent"]) {
            childrenOf[pid, default: []].append(e)
        }
    }
    for k in childrenOf.keys {
        childrenOf[k]?.sort { lhs, rhs in
            let la = Schemas.folderSchemas.contains(lhs["schema"] as? String ?? "") ? 0 : 1
            let ra = Schemas.folderSchemas.contains(rhs["schema"] as? String ?? "") ? 0 : 1
            if la != ra { return la < ra }
            return entityDisplayName(lhs).lowercased() < entityDisplayName(rhs).lowercased()
        }
    }

    var lines: [String] = [header]
    func walk(_ eid: String, prefix: String, current: Int) {
        let kids = childrenOf[eid] ?? []
        let displayed = Array(kids.prefix(maxSiblings))
        let trunc = kids.count - displayed.count
        for (i, k) in displayed.enumerated() {
            let last = (i == displayed.count - 1) && (trunc == 0)
            let branch = last ? "└── " : "├── "
            let kid = (k["id"] as? String) ?? ""
            let kalias = ((try? store.aliasFor(kid)) ?? nil) ?? "-"
            let ksch = (k["schema"] as? String) ?? "?"
            let kname = entityDisplayName(k)
            let isFolder = Schemas.folderSchemas.contains(ksch)
            var ann = ""
            if isFolder {
                let direct = (childrenOf[kid] ?? []).count
                ann = direct > 0 ? "  (\(direct))" : "  (empty)"
            }
            lines.append("\(prefix)\(branch)\(pad(kalias, to: 5)) \(Render.short(kname, width: 56)) [\(ksch)]\(ann)")
            if isFolder, current + 1 < depth {
                let nextPrefix = prefix + (last ? "    " : "│   ")
                walk(kid, prefix: nextPrefix, current: current + 1)
            } else if isFolder, current + 1 == depth, !(childrenOf[kid] ?? []).isEmpty {
                let nextPrefix = prefix + (last ? "    " : "│   ")
                lines.append("\(nextPrefix)└── … (depth limit; raise --depth to see)")
            }
        }
        if trunc > 0 {
            lines.append("\(prefix)└── … \(trunc) more entries not shown — raise --max-siblings")
        }
    }
    walk(rootId, prefix: "", current: 1)
    if hitCap {
        lines.append("")
        lines.append("warn: subtree exceeds scan cap — counts and deep branches may be incomplete")
    }
    return lines.joined(separator: "\n")
}

private func pad(_ s: String, to width: Int) -> String {
    s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
}
