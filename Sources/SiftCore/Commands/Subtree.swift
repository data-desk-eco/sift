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
    /// Aleph's `from + size` cap on `/entities`: any offset >= 10_000
    /// returns an error. We stop one page short to leave headroom.
    let offsetCap = 9800
    /// Concurrent in-flight page requests. OCCRP tolerates this fine
    /// at our scale; lifting it further hits diminishing returns once
    /// SQLite-write time matches network time.
    let pageConcurrency = 4

    let cacheArgs: [String: Any] = [
        "root": rootId, "max": maxEntities,
        "collection": collectionId ?? "",
    ]
    let key = try Store.cacheKey(command: "subtree_scan", args: cacheArgs)
    if let hit = try store.cacheGet(key) {
        let ents = (hit["entities"] as? [[String: Any]]) ?? []
        let serverName = client.serverName
        try store.withTransaction {
            for e in ents {
                try seeEntity(
                    store: store, entity: e,
                    server: serverName, collectionId: collectionId
                )
            }
        }
        let total = (hit["total"] as? Int) ?? ents.count
        let hitCap = (hit["hit_cap"] as? Bool) ?? false
        return SubtreeScanResult(entities: ents, total: total, hitCap: hitCap)
    }

    func paramsFor(offset: Int) -> [String: Any] {
        var params: [String: Any] = [
            "filter:properties.ancestors": rootId,
            "filter:schemata": Schemas.treeDocSchemas,
            "limit": pageLimit, "offset": offset,
        ]
        if let cid = collectionId { params["filter:collection_id"] = cid }
        return params
    }

    let serverName = client.serverName
    var collected: [[String: Any]] = []
    var hitCap = false

    /// Ingest a page's results into the store and append to `collected`.
    /// Returns `true` when we've hit `maxEntities` and the caller should
    /// stop. One transaction per page so 200 entities = ~1 fsync, not 200.
    func ingest(_ results: [[String: Any]], total: Int) throws -> Bool {
        try store.withTransaction {
            for e in results {
                try seeEntity(
                    store: store, entity: e,
                    server: serverName, collectionId: collectionId
                )
                collected.append(e)
                if collected.count >= maxEntities {
                    hitCap = total > collected.count
                    return
                }
            }
        }
        return hitCap
    }

    // Page 0 is sequential — we need its `total` to plan the rest.
    let firstData = try await client.get("/entities", params: paramsFor(offset: 0))
    var total = (firstData["total"] as? Int) ?? 0
    let firstResults = (firstData["results"] as? [[String: Any]]) ?? []
    if try ingest(firstResults, total: total) {
        let payload: [String: Any] = [
            "entities": collected, "total": total, "hit_cap": hitCap,
        ]
        try store.cacheSet(key, payload)
        return SubtreeScanResult(entities: collected, total: total, hitCap: hitCap)
    }
    if firstResults.count < pageLimit {
        let payload: [String: Any] = [
            "entities": collected, "total": total, "hit_cap": false,
        ]
        try store.cacheSet(key, payload)
        return SubtreeScanResult(entities: collected, total: total, hitCap: false)
    }

    // Plan remaining pages from `total`, capped by both `maxEntities`
    // and Aleph's offset ceiling. We trust the first-page total as a
    // hint; the per-page `results.count < pageLimit` short-circuit
    // still covers the case where it shifts under us.
    let pagesNeededByTotal = (total + pageLimit - 1) / pageLimit
    let pagesNeededByCap = (maxEntities + pageLimit - 1) / pageLimit
    let pagesNeededByOffset = offsetCap / pageLimit + 1
    let lastPageIndex = min(pagesNeededByTotal, pagesNeededByCap, pagesNeededByOffset)
    let remainingOffsets = (1..<lastPageIndex).map { $0 * pageLimit }
    if remainingOffsets.isEmpty {
        if total > collected.count { hitCap = true }
        let payload: [String: Any] = [
            "entities": collected, "total": total, "hit_cap": hitCap,
        ]
        try store.cacheSet(key, payload)
        return SubtreeScanResult(entities: collected, total: total, hitCap: hitCap)
    }

    // Process in batches of `pageConcurrency`: fetch in parallel,
    // ingest sequentially in offset order so `collected` stays a
    // stable parent-child traversal. A short page ends the scan early.
    var batchStart = 0
    var sawShortPage = false
    outer: while batchStart < remainingOffsets.count {
        let batchEnd = min(batchStart + pageConcurrency, remainingOffsets.count)
        let batch = Array(remainingOffsets[batchStart..<batchEnd])

        let pages: [(Int, [String: Any])] = try await withThrowingTaskGroup(
            of: (Int, [String: Any]).self
        ) { group in
            for off in batch {
                group.addTask {
                    let d = try await client.get("/entities", params: paramsFor(offset: off))
                    return (off, d)
                }
            }
            var out: [(Int, [String: Any])] = []
            for try await page in group { out.append(page) }
            return out.sorted { $0.0 < $1.0 }
        }

        for (_, data) in pages {
            if let t = data["total"] as? Int { total = t }
            let results = (data["results"] as? [[String: Any]]) ?? []
            if try ingest(results, total: total) { break outer }
            if results.count < pageLimit { sawShortPage = true; break outer }
        }
        batchStart = batchEnd
    }

    if !hitCap, !sawShortPage, lastPageIndex >= pagesNeededByOffset {
        // We hit the offset ceiling without exhausting `total`.
        hitCap = true
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
