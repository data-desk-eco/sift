import Foundation

public struct ReadInput: Sendable {
    public var alias: String
    public var full: Bool
    public var raw: Bool
    public var limit: Int?
    public init(alias: String, full: Bool = false, raw: Bool = false, limit: Int? = nil) {
        self.alias = alias; self.full = full; self.raw = raw; self.limit = limit
    }
}

public func runRead(
    client: AlephClient, store: Store, input: ReadInput
) async throws -> String {
    let eid = try store.resolveAlias(input.alias)

    var data: [String: Any]
    var cachedFromGraph = false
    if !input.raw, try store.hasFullBody(eid),
       let props = try store.cachedProperties(eid),
       let stub = try store.getEntity(eid) {
        data = [
            "id": eid,
            "schema": stub.schema,
            "caption": stub.caption ?? NSNull(),
            "properties": props,
        ]
        cachedFromGraph = true
    } else {
        let fresh = try await client.get("/entities/\(eid)")
        try seeEntity(
            store: store, entity: fresh,
            server: client.serverName, collectionId: nil, fullBody: true
        )
        data = fresh
    }

    if input.raw {
        let json = (try? Store.jsonString(data)) ?? "{}"
        return Render.envelope("read \(input.alias) --raw", json)
    }

    let props = (data["properties"] as? [String: Any]) ?? [:]
    let schema = (data["schema"] as? String) ?? ""
    let caption = (data["caption"] as? String) ?? ""
    var bodyText = Render.firstLabel(props["bodyText"])
    if bodyText.isEmpty { bodyText = Render.firstLabel(props["description"]) }
    // --limit caps the body to N chars (a middle ground between the
    // default truncation and -f full); otherwise truncate unless -f.
    if let limit = input.limit { bodyText = Render.truncate(bodyText, maxChars: max(1, limit)) }
    else if !input.full { bodyText = Render.truncate(bodyText) }

    var lines: [String] = []
    lines.append("id:       \(eid)")
    lines.append("alias:    \(input.alias)")
    if let url = alephEntityURL(eid) { lines.append("url:      \(url)") }
    lines.append("schema:   \(schema)")
    if !caption.isEmpty { lines.append("caption:  \(caption)") }
    let subject = Render.firstLabel(props["subject"])
    if !subject.isEmpty { lines.append("subject:  \(subject)") }
    let date = Render.firstLabel(props["date"])
    if !date.isEmpty { lines.append("date:     \(date)") }

    for prop in Schemas.refProperties {
        let formatted = try formatFtmRefs(store: store, value: props[prop])
        if !formatted.isEmpty {
            lines.append(pad(prop + ":", to: 9) + " " + formatted)
        }
    }

    let rawFrom = Render.firstLabel(props["from"])
    if !rawFrom.isEmpty, props["emitters"] == nil {
        lines.append("from:     \(rawFrom)")
    }
    let rawTo = Render.extractLabel(props["to"])
    if !rawTo.isEmpty, props["recipients"] == nil {
        lines.append("to:       \(rawTo)")
    }

    lines.append(Render.rule)
    lines.append(bodyText.isEmpty ? "(no body text)" : bodyText)

    let header = "read \(input.alias)" + (cachedFromGraph ? " (from cache)" : "")
    return Render.envelope(header, lines.joined(separator: "\n"))
}

private func pad(_ s: String, to width: Int) -> String {
    s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
}

/// `<ALEPH_URL>/entities/<id>` — the web ui page for this entity, for
/// citing as a link in a write-up. nil when no server url is in the env.
/// The web ui lives at the bare host; an `/api/v2` suffix is the json api
/// and won't render entity pages, so strip it.
private func alephEntityURL(_ id: String) -> String? {
    guard var base = ProcessInfo.processInfo.environment["ALEPH_URL"], !base.isEmpty
    else { return nil }
    if base.hasSuffix("/") { base.removeLast() }
    if let r = base.range(of: #"/api/v?\d+/?$"#, options: .regularExpression) {
        base = String(base[..<r.lowerBound])
    }
    return base.isEmpty ? nil : "\(base)/entities/\(id)"
}
