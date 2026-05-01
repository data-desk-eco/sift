import Foundation

public struct SimilarInput: Sendable {
    public var alias: String
    public var limit: Int
    public init(alias: String, limit: Int = 10) {
        self.alias = alias; self.limit = limit
    }
}

public func runSimilar(
    client: AlephClient, store: Store, input: SimilarInput
) async throws -> String {
    let eid = try store.resolveAlias(input.alias)

    if let stub = try store.getEntity(eid),
       !Schemas.partySchemas.contains(stub.schema) {
        throw SiftError(
            "similar only supports party schemas — \(input.alias) is a \(stub.schema)",
            suggestion: "use expand instead for documents/emails/folders"
        )
    }

    let key = try Store.cacheKey(
        command: "similar", args: ["id": eid, "limit": input.limit]
    )
    var data: [String: Any]?
    var cached = false
    if let hit = try store.cacheGet(key) {
        data = hit; cached = true
    } else {
        let fresh = try await client.get(
            "/entities/\(eid)/similar", params: ["limit": input.limit]
        )
        try store.cacheSet(key, fresh)
        data = fresh
    }

    let results = (data?["results"] as? [[String: Any]]) ?? []
    let total = (data?["total"] as? Int) ?? results.count
    if results.isEmpty {
        return Render.envelope(
            "similar \(input.alias)",
            "(no similar entities — this party is unique or isolated in its collection)"
        )
    }

    let serverName = client.serverName
    var rows: [[String]] = []
    for row in results {
        let entity = (row["entity"] as? [String: Any]) ?? row
        let scoreVal = (row["score"] as? Double)
            ?? (entity["score"] as? Double) ?? 0
        let alias = try seeEntity(
            store: store, entity: entity,
            server: serverName, collectionId: nil
        )
        let schema = (entity["schema"] as? String) ?? ""
        let props = (entity["properties"] as? [String: Any]) ?? [:]
        let nameList = props["name"] as? [Any]
        let name: String
        if let first = nameList?.first {
            name = Render.extractLabel(first)
        } else {
            name = (entity["caption"] as? String) ?? ""
        }
        let coll = ((entity["collection"] as? [String: Any])?["label"] as? String) ?? ""
        rows.append([
            alias, String(format: "%.1f", scoreVal),
            schema, Render.short(name, width: 60), Render.short(coll, width: 40),
        ])
    }
    let header = "similar \(input.alias) — \(total) name-variant candidate(s)"
    return Render.envelope(
        header,
        Table.render(rows, headers: ["alias", "score", "schema", "name", "collection"]),
        cached: cached
    )
}
