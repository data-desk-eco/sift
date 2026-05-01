import Foundation

/// Paginate a `filter:properties.ancestors` scan from the Aleph
/// `/entities` endpoint. Used by both `browse` and `tree`. Returns the
/// collected entities, the API's reported total, and whether we hit
/// the entity cap (in which case descendant counts shown to the user
/// must be marked as lower bounds).
struct SubtreeScanResult {
    var entities: [[String: Any]]
    var total: Int
    var hitCap: Bool
}

func scanSubtree(
    client: AlephClient, store: Store,
    rootId: String, collectionId: String?,
    maxEntities: Int
) async throws -> SubtreeScanResult {
    let pageLimit = 200
    let cacheArgs: [String: Any] = [
        "root": rootId, "max": maxEntities,
        "collection": collectionId ?? "",
    ]
    let key = try Store.cacheKey(command: "subtree_scan", args: cacheArgs)
    if let hit = try store.cacheGet(key) {
        let ents = (hit["entities"] as? [[String: Any]]) ?? []
        let serverName = client.serverName
        for e in ents {
            try seeEntity(
                store: store, entity: e,
                server: serverName, collectionId: collectionId
            )
        }
        let total = (hit["total"] as? Int) ?? ents.count
        let hitCap = (hit["hit_cap"] as? Bool) ?? false
        return SubtreeScanResult(entities: ents, total: total, hitCap: hitCap)
    }

    var collected: [[String: Any]] = []
    var total = 0
    var offset = 0
    var hitCap = false
    while true {
        var params: [String: Any] = [
            "filter:properties.ancestors": rootId,
            "filter:schemata": Schemas.treeDocSchemas,
            "limit": pageLimit, "offset": offset,
        ]
        if let cid = collectionId { params["filter:collection_id"] = cid }
        let data = try await client.get("/entities", params: params)
        total = (data["total"] as? Int) ?? total
        let results = (data["results"] as? [[String: Any]]) ?? []
        let serverName = client.serverName
        for e in results {
            try seeEntity(
                store: store, entity: e,
                server: serverName, collectionId: collectionId
            )
            collected.append(e)
            if collected.count >= maxEntities {
                hitCap = total > collected.count
                let payload: [String: Any] = [
                    "entities": collected, "total": total, "hit_cap": hitCap,
                ]
                try store.cacheSet(key, payload)
                return SubtreeScanResult(entities: collected, total: total, hitCap: hitCap)
            }
        }
        if results.count < pageLimit { break }
        offset += pageLimit
        if offset >= 9800 { hitCap = true; break }
    }
    if total > collected.count { hitCap = true }
    let payload: [String: Any] = [
        "entities": collected, "total": total, "hit_cap": hitCap,
    ]
    try store.cacheSet(key, payload)
    return SubtreeScanResult(entities: collected, total: total, hitCap: hitCap)
}

func entityDisplayName(_ entity: [String: Any]) -> String {
    let p = (entity["properties"] as? [String: Any]) ?? [:]
    for c in ["fileName", "title", "subject", "name"] {
        let v = Render.firstLabel(p[c])
        if !v.isEmpty { return v }
    }
    return (entity["caption"] as? String)
        ?? (entity["id"] as? String) ?? ""
}

func countDescendants(
    rootId: String,
    childrenOf: [String: [[String: Any]]]
) -> Int {
    var stack = [rootId]
    var visited: Set<String> = [rootId]
    var n = 0
    while let cur = stack.popLast() {
        for kid in childrenOf[cur] ?? [] {
            guard let kidId = kid["id"] as? String, !visited.contains(kidId) else { continue }
            visited.insert(kidId)
            n += 1
            stack.append(kidId)
        }
    }
    return n
}
