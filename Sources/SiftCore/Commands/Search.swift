import Foundation

public struct SearchInput: Sendable {
    public var query: String
    public var type: String
    public var limit: Int
    public var offset: Int
    public var collection: String?
    public var sortByDate: Bool
    public var noCache: Bool
    public var emitter: String?
    public var recipient: String?
    public var mentions: String?
    public var dateFrom: String?
    public var dateTo: String?

    public init(
        query: String = "",
        type: String = "any",
        limit: Int = 10,
        offset: Int = 0,
        collection: String? = nil,
        sortByDate: Bool = false,
        noCache: Bool = false,
        emitter: String? = nil,
        recipient: String? = nil,
        mentions: String? = nil,
        dateFrom: String? = nil,
        dateTo: String? = nil
    ) {
        self.query = query
        self.type = type
        self.limit = limit
        self.offset = offset
        self.collection = collection
        self.sortByDate = sortByDate
        self.noCache = noCache
        self.emitter = emitter
        self.recipient = recipient
        self.mentions = mentions
        self.dateFrom = dateFrom
        self.dateTo = dateTo
    }
}

public func runSearch(
    client: AlephClient, store: Store, input: SearchInput
) async throws -> String {

    let emitterId  = try store.resolveOptional(input.emitter)
    let recipientId = try store.resolveOptional(input.recipient)
    let mentionsId  = try store.resolveOptional(input.mentions)

    // Party filters imply emails.
    var effectiveType = input.type
    if emitterId != nil || recipientId != nil { effectiveType = "emails" }

    // Cache key uses resolved ids so equivalent aliases collapse.
    let cacheArgs: [String: Any] = [
        "q": input.query, "type": effectiveType,
        "limit": input.limit, "offset": input.offset,
        "collection": input.collection ?? NSNull(),
        "emitter": emitterId ?? NSNull(),
        "recipient": recipientId ?? NSNull(),
        "mentions": mentionsId ?? NSNull(),
        "date_from": input.dateFrom ?? NSNull(),
        "date_to": input.dateTo ?? NSNull(),
    ]
    let key = try Store.cacheKey(command: "search", args: cacheArgs)

    var data: [String: Any]?
    var cached = false
    if !input.noCache, let hit = try store.cacheGet(key) {
        data = hit
        cached = true
    }
    if data == nil {
        let params = makeParams(
            query: input.query, type: effectiveType,
            limit: input.limit, offset: input.offset,
            collection: input.collection,
            emitterId: emitterId, recipientId: recipientId, mentionsId: mentionsId,
            dateFrom: input.dateFrom, dateTo: input.dateTo
        )
        let fresh = try await client.get("/entities", params: params)
        try store.cacheSet(key, fresh)
        data = fresh
    }

    var results = (data?["results"] as? [[String: Any]]) ?? []
    let total = (data?["total"] as? Int) ?? results.count
    let totalType = (data?["total_type"] as? String) ?? "eq"

    if input.sortByDate {
        results.sort { lhs, rhs in
            let l = Render.firstLabel((lhs["properties"] as? [String: Any])?["date"])
            let r = Render.firstLabel((rhs["properties"] as? [String: Any])?["date"])
            return l < r
        }
    }

    var dropped = 0
    if effectiveType == "emails" {
        let (kept, n) = dedupeEmails(results)
        results = kept
        dropped = n
    }

    let isEmailView = effectiveType == "emails"
    let serverName = client.serverName
    var rows: [[String]] = []
    for entity in results {
        let alias = try seeEntity(
            store: store, entity: entity,
            server: serverName, collectionId: input.collection
        )
        rows.append(isEmailView ? emailRow(alias, entity) : genericRow(alias, entity))
    }
    let headers = isEmailView
        ? ["alias", "date", "from", "subject"]
        : ["alias", "date", "schema", "title"]

    let shownStart = results.isEmpty ? input.offset : input.offset + 1
    let shownEnd   = input.offset + results.count
    let queryLabel = input.query.isEmpty ? "(no text query)" : "\"\(input.query)\""
    let totalStr = totalType == "gte" ? "\(total)+" : "\(total)"

    var header = "search \(queryLabel) --type \(effectiveType)  \(totalStr) hits, showing \(shownStart)-\(shownEnd)"
    if let raw = input.emitter,    emitterId   != nil { header += "  --emitter \(raw)" }
    if let raw = input.recipient,  recipientId != nil { header += "  --recipient \(raw)" }
    if let raw = input.mentions,   mentionsId  != nil { header += "  --mentions \(raw)" }
    if let f = input.dateFrom { header += "  --date-from \(f)" }
    if let t = input.dateTo   { header += "  --date-to \(t)" }
    if input.sortByDate       { header += "  (sorted by date)" }
    if let c = input.collection { header += "  --collection \(c)" }

    var body = ""
    if results.isEmpty {
        body = "(no results)"
    } else {
        body = Table.render(rows, headers: headers)
        if dropped > 0 {
            body += "\n\n[+\(dropped) duplicate-subject emails collapsed]"
        }
        let after = input.offset + results.count
        if after < total {
            let nextOffset = input.offset + input.limit
            let remaining = max(0, total - after)
            let tail = totalType == "gte" ? "\(remaining)+" : "\(remaining)"
            body += "\n[\(tail) more hits — call search again with --offset \(nextOffset)]"
        }
    }
    return Render.envelope(header, body, cached: cached)
}

// MARK: - helpers

private func makeParams(
    query: String, type: String, limit: Int, offset: Int,
    collection: String?,
    emitterId: String?, recipientId: String?, mentionsId: String?,
    dateFrom: String?, dateTo: String?
) -> [String: Any] {
    var params: [String: Any] = ["q": query, "limit": limit]
    if offset > 0 { params["offset"] = offset }
    if type == "any" {
        params["filter:schemata"] = Schemas.anyTypeSchemas
    } else if let schema = Schemas.typeToSchema[type] {
        params["filter:schemata"] = schema
    }
    if let c = collection { params["filter:collection_id"] = c }
    if let id = emitterId   { params["filter:properties.emitters"]   = id }
    if let id = recipientId { params["filter:properties.recipients"] = id }
    if let id = mentionsId  { params["filter:properties.mentions"]   = id }
    if let f = dateFrom, let t = dateTo {
        params["filter:dates"] = "\(f)..\(t)"
    } else if let f = dateFrom {
        params["filter:dates"] = "\(f)..*"
    } else if let t = dateTo {
        params["filter:dates"] = "*..\(t)"
    }
    // Property-filtered searches require schemata on Aleph Pro.
    if (emitterId != nil || recipientId != nil || mentionsId != nil),
       params["filter:schemata"] == nil {
        params["filter:schemata"] = "Email"
    }
    return params
}

private func emailRow(_ alias: String, _ entity: [String: Any]) -> [String] {
    let props = (entity["properties"] as? [String: Any]) ?? [:]
    let date = String(Render.firstLabel(props["date"]).prefix(10))
    let senderRaw = Render.firstLabel(props["from"])
    let sender = Render.stripEmailAddress(senderRaw.isEmpty ? "unknown" : senderRaw)
    let subject = Render.firstLabel(props["subject"]).isEmpty
        ? ((entity["title"] as? String) ?? "(no subject)")
        : Render.firstLabel(props["subject"])
    return [alias, date, Render.short(sender, width: 30), Render.short(subject, width: 80)]
}

private func genericRow(_ alias: String, _ entity: [String: Any]) -> [String] {
    let props = (entity["properties"] as? [String: Any]) ?? [:]
    let schema = (entity["schema"] as? String) ?? ""
    // Subject wins for emails; everything else uses title/name/fileName ordering.
    let candidates: [String] = (schema == "Email")
        ? ["subject", "title", "name", "fileName"]
        : ["title", "name", "fileName", "subject"]
    var title = ""
    for k in candidates {
        let v = Render.firstLabel(props[k])
        if !v.isEmpty { title = v; break }
    }
    if title.isEmpty {
        title = (entity["title"] as? String)
            ?? (entity["name"] as? String)
            ?? "(untitled)"
    }
    let date = String(
        (Render.firstLabel(props["date"]).isEmpty
            ? Render.firstLabel(props["createdAt"])
            : Render.firstLabel(props["date"])).prefix(10)
    )
    return [alias, date, schema, Render.short(title, width: 80)]
}

private func dedupeEmails(_ results: [[String: Any]]) -> ([[String: Any]], Int) {
    var groups: [String: [[String: Any]]] = [:]
    var order: [String] = []
    for entity in results {
        let props = (entity["properties"] as? [String: Any]) ?? [:]
        let subj = Render.firstLabel(props["subject"])
        let key: String
        if !subj.isEmpty {
            key = Render.normalizeSubject(subj)
        } else {
            key = (entity["id"] as? String) ?? ""
        }
        if groups[key] == nil { order.append(key) }
        groups[key, default: []].append(entity)
    }
    var kept: [[String: Any]] = []
    var dropped = 0
    for k in order {
        let members = (groups[k] ?? []).sorted {
            ($0["id"] as? String ?? "") < ($1["id"] as? String ?? "")
        }
        if let first = members.first { kept.append(first) }
        dropped += max(0, members.count - 1)
    }
    return (kept, dropped)
}
