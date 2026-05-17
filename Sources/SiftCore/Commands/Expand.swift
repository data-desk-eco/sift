import Foundation

public struct ExpandInput: Sendable {
    public var alias: String
    public var property: String?
    public var limit: Int
    public var noCache: Bool
    public init(alias: String, property: String? = nil, limit: Int = 20, noCache: Bool = false) {
        self.alias = alias; self.property = property
        self.limit = limit; self.noCache = noCache
    }
}

public func runExpand(
    client: AlephClient, store: Store, input: ExpandInput
) async throws -> String {
    let eid = try store.resolveAlias(input.alias)
    var params: [String: Any] = ["limit": input.limit]
    if let p = input.property { params["filter:property"] = p }

    let (data, cached) = try await store.cacheOrFetch(
        command: "expand",
        args: ["id": eid, "property": input.property ?? NSNull(), "limit": input.limit],
        skipCache: input.noCache
    ) {
        try await client.get("/entities/\(eid)/expand", params: params)
    }

    let groups = (data["results"] as? [[String: Any]]) ?? []

    let stub = try store.getEntity(eid)
    let isParty = stub.map { Schemas.partySchemas.contains($0.schema) } ?? false
    let totalInGroups = groups.reduce(0) { $0 + ((($1["entities"] as? [Any])?.count) ?? 0) }
    if isParty, totalInGroups == 0 {
        let rows: [[String]] = groups.map {
            let prop = ($0["property"] as? String) ?? "?"
            let count = ($0["count"] as? Int) ?? 0
            return [prop, String(count)]
        }
        let body = "expand on a party returns reverse-property counts only — use "
            + "`search --recipient`, `--emitter`, or `--mentions` to enumerate.\n\n"
            + Table.render(rows, headers: ["property", "count"])
        return Render.envelope("expand \(input.alias)", body)
    }
    if groups.isEmpty {
        return Render.envelope("expand \(input.alias)", "(no related entities)")
    }

    let sorted = groups.sorted {
        (($0["count"] as? Int) ?? 0) > (($1["count"] as? Int) ?? 0)
    }
    let serverName = client.serverName
    var totalSeen = 0
    var sections: [String] = []
    for group in sorted {
        let prop = (group["property"] as? String) ?? "?"
        let count = (group["count"] as? Int) ?? 0
        let entities = (group["entities"] as? [[String: Any]]) ?? []
        if entities.isEmpty { continue }
        var rows: [[String]] = []
        for e in entities {
            let alias = try seeEntity(
                store: store, entity: e,
                server: serverName, collectionId: nil
            )
            let schema = (e["schema"] as? String) ?? ""
            let props = (e["properties"] as? [String: Any]) ?? [:]
            var name = Render.firstLabel(props["name"])
            if name.isEmpty { name = Render.firstLabel(props["subject"]) }
            if name.isEmpty { name = (e["caption"] as? String) ?? "" }
            let date = String(Render.firstLabel(props["date"]).prefix(10))
            rows.append([alias, schema, Render.short(name, width: 70), date])
            totalSeen += 1
        }
        let suffix = entities.count < count ? ", showing \(entities.count)" : ""
        sections.append("")
        sections.append("## \(prop) (\(count)\(suffix))")
        sections.append(Table.render(rows, headers: ["alias", "schema", "name", "date"]))
    }
    let header = "expand \(input.alias) — \(totalSeen) related across \(groups.count) properties"
    return Render.envelope(header, sections.joined(separator: "\n"), cached: cached)
}
