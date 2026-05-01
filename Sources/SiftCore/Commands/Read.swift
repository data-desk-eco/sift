import Foundation

public struct ReadInput: Sendable {
    public var alias: String
    public var full: Bool
    public var raw: Bool
    public init(alias: String, full: Bool = false, raw: Bool = false) {
        self.alias = alias; self.full = full; self.raw = raw
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
    if !input.full { bodyText = Render.truncate(bodyText) }

    var lines: [String] = []
    lines.append("id:       \(eid)")
    lines.append("alias:    \(input.alias)")
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
