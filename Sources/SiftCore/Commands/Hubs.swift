import Foundation

public struct HubsInput: Sendable {
    public var query: String
    public var collection: String?
    public var schema: String
    public var limit: Int
    public init(query: String = "", collection: String? = nil,
                schema: String = "Email", limit: Int = 10) {
        self.query = query; self.collection = collection
        self.schema = schema; self.limit = limit
    }
}

public func runHubs(
    client: AlephClient, store: Store, input: HubsInput
) async throws -> String {
    let topN = max(1, min(25, input.limit))

    var apiParams: [String: Any] = [
        "filter:schemata": input.schema,
        "limit": 0,
        "facet": [
            "properties.emitters",
            "properties.recipients",
            "properties.peopleMentioned",
            "properties.companiesMentioned",
        ],
        "facet_size:properties.emitters": topN,
        "facet_size:properties.recipients": topN,
        "facet_size:properties.peopleMentioned": topN,
        "facet_size:properties.companiesMentioned": topN,
    ]
    if !input.query.isEmpty { apiParams["q"] = input.query }
    if let c = input.collection { apiParams["filter:collection_id"] = c }

    let cacheArgs: [String: Any] = [
        "q": input.query, "schema": input.schema,
        "collection": input.collection ?? NSNull(), "topN": topN,
    ]
    let key = try Store.cacheKey(command: "hubs_facet", args: cacheArgs)
    var data: [String: Any]?
    var cached = false
    if let hit = try store.cacheGet(key) {
        data = hit; cached = true
    }
    if data == nil {
        let fresh = try await client.get("/entities", params: apiParams)
        try store.cacheSet(key, fresh)
        data = fresh
    }

    let total = (data?["total"] as? Int) ?? 0
    let facets = (data?["facets"] as? [String: Any]) ?? [:]
    let serverName = client.serverName

    // Backfill missing party stubs so facet rows show readable names.
    var partyIds: Set<String> = []
    for facetKey in ["properties.emitters", "properties.recipients"] {
        let values = ((facets[facetKey] as? [String: Any])?["values"] as? [[String: Any]]) ?? []
        for v in values {
            if let id = v["id"] as? String, !id.isEmpty { partyIds.insert(id) }
        }
    }
    for pid in partyIds {
        let stub = try store.getEntity(pid)
        let needsFetch = stub == nil
            || (stub?.schema == "LegalEntity" && (stub?.name ?? "").isEmpty)
        if needsFetch {
            if let fresh = try? await client.get("/entities/\(pid)") {
                try seeEntity(
                    store: store, entity: fresh,
                    server: serverName, collectionId: input.collection
                )
            }
        }
    }

    let qLabel = input.query.isEmpty ? "(all)" : "\"\(input.query)\""
    var out: [String] = [
        "\(total) \(input.schema.lowercased()) matches for \(qLabel) "
            + "in collection \(input.collection ?? "any")"
    ]

    func renderEntityFacet(title: String, key: String) throws {
        let values = ((facets[key] as? [String: Any])?["values"] as? [[String: Any]]) ?? []
        if values.isEmpty { return }
        var rows: [[String]] = []
        for v in values {
            guard let id = v["id"] as? String, !id.isEmpty else { continue }
            let count = (v["count"] as? Int) ?? 0
            var stub = try store.getEntity(id)
            if stub == nil {
                try store.remember(
                    eid: id, schema: "LegalEntity", caption: nil, name: nil,
                    properties: nil, collectionId: input.collection,
                    server: serverName, fullBody: false
                )
                stub = try store.getEntity(id)
            }
            let alias = try store.assignAlias(id)
            let display = stub?.name ?? stub?.caption ?? "(unnamed)"
            rows.append([alias, String(count), Render.short(display, width: 80)])
        }
        if !rows.isEmpty {
            out.append("")
            out.append("## \(title)")
            out.append(Table.render(rows, headers: ["alias", "count", "name"]))
        }
    }

    func renderStringFacet(title: String, key: String) {
        let values = ((facets[key] as? [String: Any])?["values"] as? [[String: Any]]) ?? []
        if values.isEmpty { return }
        let rows: [[String]] = values.map {
            let count = ($0["count"] as? Int) ?? 0
            let label = ($0["label"] as? String) ?? ($0["id"] as? String) ?? "?"
            return [String(count), Render.short(label, width: 80)]
        }
        out.append("")
        out.append("## \(title)")
        out.append(Table.render(rows, headers: ["count", "label"]))
    }

    try renderEntityFacet(title: "Top senders (emitters)", key: "properties.emitters")
    try renderEntityFacet(title: "Top recipients", key: "properties.recipients")
    renderStringFacet(title: "Top people mentioned", key: "properties.peopleMentioned")
    renderStringFacet(title: "Top companies mentioned", key: "properties.companiesMentioned")

    return Render.envelope("hubs \(qLabel)", out.joined(separator: "\n"), cached: cached)
}
