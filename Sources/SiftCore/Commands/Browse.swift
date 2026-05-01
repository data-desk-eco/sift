import Foundation

public struct BrowseInput: Sendable {
    public var alias: String
    public var limit: Int
    public init(alias: String, limit: Int = 30) {
        self.alias = alias; self.limit = limit
    }
}

public func runBrowse(
    client: AlephClient, store: Store, input: BrowseInput
) async throws -> String {
    let eid = try store.resolveAlias(input.alias)
    let stub = try store.getEntity(eid)
    var targetProps = (try store.cachedProperties(eid)) ?? [:]
    let schema = stub?.schema ?? ""
    let isFolder = Schemas.folderSchemas.contains(schema)

    let folderId: String
    if isFolder {
        folderId = eid
    } else {
        if let parent = Render.firstEntityRefId(targetProps["parent"]) {
            folderId = parent
        } else {
            let fresh = try await client.get("/entities/\(eid)")
            try seeEntity(
                store: store, entity: fresh,
                server: client.serverName, collectionId: nil, fullBody: true
            )
            let freshProps = (fresh["properties"] as? [String: Any]) ?? [:]
            guard let parent = Render.firstEntityRefId(freshProps["parent"]) else {
                return Render.envelope(
                    "browse \(input.alias)",
                    "(no parent folder on record — this entity may be at the collection root)"
                )
            }
            targetProps = freshProps
            folderId = parent
        }
    }

    let cid = try store.collectionOf(eid)
    let scan = try await scanSubtree(
        client: client, store: store,
        rootId: folderId, collectionId: cid, maxEntities: 1000
    )

    var childrenOf: [String: [[String: Any]]] = [:]
    for e in scan.entities {
        let props = (e["properties"] as? [String: Any]) ?? [:]
        if let pid = Render.firstEntityRefId(props["parent"]) {
            childrenOf[pid, default: []].append(e)
        }
    }

    let direct = childrenOf[folderId] ?? []
    let displayed = Array(direct.prefix(input.limit))
    let truncated = direct.count - displayed.count

    var siblingRows: [[String]] = []
    for s in displayed {
        let sid = (s["id"] as? String) ?? ""
        let salias = (try store.aliasFor(sid)) ?? "-"
        let sschema = (s["schema"] as? String) ?? ""
        let sname = entityDisplayName(s)
        let marker = sid == eid ? "›" : ""
        var contents = ""
        if Schemas.folderSchemas.contains(sschema) {
            let kidsN = (childrenOf[sid] ?? []).count
            if scan.hitCap, kidsN > 0 {
                contents = "\(kidsN)+ desc"
            } else if kidsN > 0 {
                contents = "\(countDescendants(rootId: sid, childrenOf: childrenOf)) desc"
            } else {
                contents = "empty"
            }
        }
        siblingRows.append([
            marker, salias, sschema, Render.short(sname, width: 80), contents,
        ])
    }

    var breadcrumb: [String] = []
    let aids = Render.referencedIdStrings(targetProps["ancestors"])
    for aid in aids.prefix(8) {
        let a = (try store.aliasFor(aid)) ?? "-"
        let st = try store.getEntity(aid)
        let nm = st?.name ?? st?.caption ?? String(aid.prefix(8))
        breadcrumb.append("\(a) \(nm)")
    }

    let folderAlias = (try store.aliasFor(folderId)) ?? "-"
    let folderStub = try store.getEntity(folderId)
    let folderName = folderStub?.name ?? folderStub?.caption ?? String(folderId.prefix(10))

    var out: [String] = []
    if !breadcrumb.isEmpty {
        out.append("path: " + breadcrumb.joined(separator: " / "))
    }
    out.append("folder: \(folderAlias) \(folderName)")
    out.append("")
    if siblingRows.isEmpty {
        out.append("(no contents)")
    } else {
        let totalStr = scan.hitCap ? "\(scan.total)+" : "\(scan.entities.count)"
        out.append("contents (direct: \(direct.count); subtree: \(totalStr)):")
        out.append(Table.render(
            siblingRows,
            headers: ["here", "alias", "schema", "name", "contents"]
        ))
        if truncated > 0 {
            out.append("… \(truncated) more not shown — raise --limit to see them")
        }
    }
    if scan.hitCap {
        out.append("")
        out.append("warn: subtree larger than scan cap — descendant counts marked '+' are lower bounds")
    }

    return Render.envelope("browse \(input.alias)", out.joined(separator: "\n"))
}
