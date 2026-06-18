import Foundation

/// `sift entity …` — create, edit, delete, list and inspect the agent's
/// own FollowTheMoney findings. Pure logic returning rendered envelopes;
/// the CLI wrappers in SiftCLI own argument parsing.
///
/// Entity references in properties (`payer`, `owner`, `member`, …) accept
/// a findings alias (`f3`), an Aleph alias (`r5`), or a raw id, and are
/// resolved to ids on write so the graph is internally consistent.

// MARK: - Inputs

public struct EntityCreateInput: Sendable {
    public var schema: String?
    public var json: String?
    public var props: [String]
    public var sources: [String]
    public init(schema: String? = nil, json: String? = nil, props: [String] = [], sources: [String] = []) {
        self.schema = schema; self.json = json; self.props = props; self.sources = sources
    }
}

public struct EntityEditInput: Sendable {
    public var alias: String
    public var schema: String?
    public var json: String?
    public var props: [String]
    public var removeProps: [String]
    public var sources: [String]?
    public init(alias: String, schema: String? = nil, json: String? = nil,
                props: [String] = [], removeProps: [String] = [], sources: [String]? = nil) {
        self.alias = alias; self.schema = schema; self.json = json
        self.props = props; self.removeProps = removeProps; self.sources = sources
    }
}

public struct EntityDeleteInput: Sendable {
    public var alias: String
    public var force: Bool
    public init(alias: String, force: Bool = false) { self.alias = alias; self.force = force }
}

public struct EntityListInput: Sendable {
    public var schema: String?
    public var json: Bool
    public init(schema: String? = nil, json: Bool = false) { self.schema = schema; self.json = json }
}

public struct EntityShowInput: Sendable {
    public var alias: String
    public var json: Bool
    public init(alias: String, json: Bool = false) { self.alias = alias; self.json = json }
}

// MARK: - Create

public func runEntityCreate(
    findings: FindingsStore, aleph: Store, input: EntityCreateInput
) throws -> String {
    var raw: [String: Any] = [:]
    var jsonSchema: String?
    if let json = input.json, !json.isEmpty {
        let (s, p) = try parseJSONEntity(json)
        jsonSchema = s
        raw = p
    }
    for (k, v) in try parseProps(input.props) { raw[k] = v }

    guard let schemaName = input.schema ?? jsonSchema else {
        throw SiftError(
            "no schema given",
            suggestion: "pass a schema (`sift entity create Person …`) or include it in --json"
        )
    }
    let norm = try Ftm.normalize(schema: schemaName, properties: raw)
    let def = Ftm.schema(norm.schema)!

    let resolver = RefResolver(findings: findings, aleph: aleph)
    let resolved = try resolveEntityRefs(norm.properties, schema: def, findings: findings, aleph: aleph)
    let caption = deriveCaption(schema: def, props: resolved, resolver: resolver)
    let sourceIds = try splitSources(input.sources).map {
        try resolveRef($0, findings: findings, aleph: aleph)
    }

    let row = try findings.create(
        schema: norm.schema, caption: caption, properties: resolved, sources: sourceIds
    )
    return render(row, header: "entity create \(row.alias) \(row.schema)",
                  resolver: resolver, warnings: norm.warnings)
}

// MARK: - Edit

public func runEntityEdit(
    findings: FindingsStore, aleph: Store, input: EntityEditInput
) throws -> String {
    let id = try findings.resolveAlias(input.alias)
    guard let existing = try findings.get(id: id) else {
        throw SiftError("unknown findings alias '\(input.alias)'",
                        suggestion: "run `sift entity list`")
    }

    var raw: [String: Any] = existing.properties
    var schemaName = existing.schema
    if let json = input.json, !json.isEmpty {
        let (s, p) = try parseJSONEntity(json)
        raw = p                     // --json replaces the whole property set
        if let s { schemaName = s }
    }
    if let s = input.schema { schemaName = s }
    for (k, v) in try parseProps(input.props) { raw[k] = v }
    for k in input.removeProps { raw.removeValue(forKey: k) }

    let norm = try Ftm.normalize(schema: schemaName, properties: raw)
    let def = Ftm.schema(norm.schema)!

    let resolver = RefResolver(findings: findings, aleph: aleph)
    let resolved = try resolveEntityRefs(norm.properties, schema: def, findings: findings, aleph: aleph)
    let caption = deriveCaption(schema: def, props: resolved, resolver: resolver)
    let sourceIds: [String]
    if let s = input.sources {
        sourceIds = try splitSources(s).map { try resolveRef($0, findings: findings, aleph: aleph) }
    } else {
        sourceIds = existing.sources
    }

    try findings.update(
        id: id, schema: norm.schema, caption: caption,
        properties: resolved, sources: sourceIds
    )
    let updated = try findings.get(id: id)!
    return render(updated, header: "entity edit \(updated.alias) \(updated.schema)",
                  resolver: resolver, warnings: norm.warnings)
}

// MARK: - Delete

public func runEntityDelete(
    findings: FindingsStore, aleph: Store, input: EntityDeleteInput
) throws -> String {
    let id = try findings.resolveAlias(input.alias)
    guard let row = try findings.get(id: id) else {
        throw SiftError("unknown findings alias '\(input.alias)'",
                        suggestion: "run `sift entity list`")
    }
    let referrers = try findings.referencing(id: id)
    if !referrers.isEmpty, !input.force {
        let names = referrers.map { "\($0.alias) (\($0.schema))" }.joined(separator: ", ")
        throw SiftError(
            "\(row.alias) is still referenced by \(names)",
            suggestion: "edit those entities first, or pass --force to delete anyway"
        )
    }
    _ = try findings.delete(id: id)
    var body = "deleted \(row.alias) — \(row.schema)\(row.caption.map { ": \($0)" } ?? "")"
    if !referrers.isEmpty {
        let names = referrers.map(\.alias).joined(separator: ", ")
        body += "\nnote: still referenced by \(names) — those refs now dangle"
    }
    return Render.envelope("entity delete \(row.alias)", body)
}

// MARK: - List

public func runEntityList(
    findings: FindingsStore, aleph: Store, input: EntityListInput
) throws -> String {
    let rows = try findings.list(schema: input.schema)
    if input.json {
        let arr = rows.map { ftmObject($0) }
        let json = (try? Store.jsonString(arr, sortedKeys: true)) ?? "[]"
        return Render.envelope("entity list --json", json)
    }
    let scope = input.schema.map { " \($0)" } ?? ""
    guard !rows.isEmpty else {
        return Render.envelope("entity list\(scope)", "(no findings yet — `sift entity create …`)")
    }
    let resolver = RefResolver(findings: findings, aleph: aleph)
    let lines = rows.map { row -> String in
        let cap = Render.short(row.caption ?? edgeCaption(row, resolver: resolver) ?? "", width: 44)
        let src = row.sources.isEmpty ? "" : "  ← " + row.sources.map { resolver.display($0).alias }.joined(separator: ",")
        return pad(row.alias, 5) + pad(row.schema, 15) + cap + src
    }
    let header = "entity list\(scope) (\(rows.count))"
    return Render.envelope(header, lines.joined(separator: "\n"))
}

// MARK: - Show

public func runEntityShow(
    findings: FindingsStore, aleph: Store, input: EntityShowInput
) throws -> String {
    let id = try findings.resolveAlias(input.alias)
    guard let row = try findings.get(id: id) else {
        throw SiftError("unknown findings alias '\(input.alias)'",
                        suggestion: "run `sift entity list`")
    }
    if input.json {
        let json = (try? Store.jsonString(ftmObject(row), sortedKeys: true)) ?? "{}"
        return Render.envelope("entity show \(row.alias) --json", json)
    }
    let resolver = RefResolver(findings: findings, aleph: aleph)
    return render(row, header: "entity show \(row.alias)", resolver: resolver, warnings: [])
}

// MARK: - Schemas

public func runEntitySchemas(name: String?) -> String {
    if let name, !name.isEmpty {
        guard let def = Ftm.schema(name) else {
            return Render.envelope("entity schemas", "unknown schema '\(name)' — try `sift entity schemas`")
        }
        var lines: [String] = []
        if def.isEdge, let s = def.source, let t = def.target {
            lines.append("edge: \(s) → \(t)")
            lines.append(Render.rule)
        }
        for key in def.props.keys.sorted() {
            let type = def.props[key]!
            let mark = type == .entity ? "  (ref)" : ""
            lines.append(pad(key, 22) + type.rawValue + mark)
        }
        return Render.envelope("entity schemas \(def.name)", lines.joined(separator: "\n"))
    }
    let entities = Ftm.registry.filter { !$0.isEdge }.map(\.name).sorted()
    let edges = Ftm.registry.filter { $0.isEdge }.map(\.name).sorted()
    let body = """
        entities:  \(entities.joined(separator: ", "))

        edges:     \(edges.joined(separator: ", "))

        `sift entity schemas <Schema>` lists a schema's properties.
        """
    return Render.envelope("entity schemas", body)
}

// MARK: - Reference resolution

/// Resolve an `f`/`r` alias (or raw id) to an entity id.
func resolveRef(_ aliasOrId: String, findings: FindingsStore, aleph: Store) throws -> String {
    let s = aliasOrId.trimmingCharacters(in: .whitespaces)
    if s.range(of: #"^f\d+$"#, options: .regularExpression) != nil {
        return try findings.resolveAlias(s)
    }
    if s.range(of: #"^r\d+$"#, options: .regularExpression) != nil {
        return try aleph.resolveAlias(s)
    }
    return s
}

func resolveEntityRefs(
    _ props: [String: [String]], schema: Ftm.SchemaDef,
    findings: FindingsStore, aleph: Store
) throws -> [String: [String]] {
    var out = props
    for prop in schema.entityProps {
        guard let vals = out[prop] else { continue }
        out[prop] = try vals.map { try resolveRef($0, findings: findings, aleph: aleph) }
    }
    return out
}

/// Looks up an entity id in the findings store, then the Aleph cache, to
/// render a `<alias> <label>` reference.
struct RefResolver {
    let findings: FindingsStore
    let aleph: Store

    func display(_ id: String) -> (alias: String, label: String) {
        if let f = try? findings.get(id: id) { return (f.alias, f.caption ?? f.schema) }
        if let row = try? aleph.getEntity(id) {
            let alias = (try? aleph.aliasFor(id)) ?? nil
            let label = row.name ?? row.caption ?? String(id.prefix(10))
            return (alias ?? "?", label)
        }
        return ("?", String(id.prefix(10)))
    }
}

// MARK: - Rendering

/// `<ALEPH_URL>/entities/<id>` for an aleph-sourced finding, or nil when
/// the source isn't an aleph entity or no server url is in the env. The
/// web ui lives at the bare host; an `/api/v2` suffix is the json api and
/// won't render entity pages, so strip it.
private func alephLink(_ id: String, alias: String) -> String? {
    guard alias.hasPrefix("r"),
          var base = ProcessInfo.processInfo.environment["ALEPH_URL"], !base.isEmpty
    else { return nil }
    if base.hasSuffix("/") { base.removeLast() }
    if let r = base.range(of: #"/api/v?\d+/?$"#, options: .regularExpression) {
        base = String(base[..<r.lowerBound])
    }
    return base.isEmpty ? nil : "\(base)/entities/\(id)"
}

private func render(
    _ row: FindingsStore.Finding, header: String,
    resolver: RefResolver, warnings: [String]
) -> String {
    var head: [String] = [
        pad("id:", 10) + row.id,
        pad("alias:", 10) + row.alias,
        pad("schema:", 10) + row.schema,
    ]
    if let cap = row.caption ?? edgeCaption(row, resolver: resolver) {
        head.append(pad("caption:", 10) + cap)
    }
    if !row.sources.isEmpty {
        let refs = row.sources.map { id -> String in
            let d = resolver.display(id)
            let label = "\(d.alias) \(Render.short(d.label, width: 28))"
            // aleph sources (r-aliases) get a clickable entity url so the
            // report can cite a durable link, not just a session-local alias.
            return alephLink(id, alias: d.alias).map { "\(label)  \($0)" } ?? label
        }
        head.append(pad("sources:", 10) + refs.joined(separator: ", "))
    }

    let def = Ftm.schema(row.schema)
    var body: [String] = []
    for prop in orderedProps(row, def: def) {
        guard let vals = row.properties[prop], !vals.isEmpty else { continue }
        body.append(pad(prop + ":", 16) + formatValues(prop, vals, def: def, resolver: resolver))
    }

    var out = head.joined(separator: "\n")
    if !body.isEmpty { out += "\n" + Render.rule + "\n" + body.joined(separator: "\n") }
    for w in warnings { out += "\nnote: \(w)" }
    return Render.envelope(header, out)
}

private func orderedProps(_ row: FindingsStore.Finding, def: Ftm.SchemaDef?) -> [String] {
    let present = Set(row.properties.keys)
    var order: [String] = []
    if let def, def.isEdge {
        for p in [def.source, def.target].compactMap({ $0 }) where present.contains(p) {
            order.append(p)
        }
    }
    order.append(contentsOf: present.subtracting(order).sorted())
    return order
}

private func formatValues(
    _ prop: String, _ vals: [String], def: Ftm.SchemaDef?, resolver: RefResolver
) -> String {
    if def?.props[prop] == .entity {
        return vals.map { id in
            let d = resolver.display(id)
            return "\(d.alias) \(Render.short(d.label, width: 28))"
        }.joined(separator: ", ")
    }
    return vals.joined(separator: ", ")
}

/// "<source> → <target>" caption for an edge with no explicit name.
private func edgeCaption(_ row: FindingsStore.Finding, resolver: RefResolver) -> String? {
    guard let def = Ftm.schema(row.schema), def.isEdge,
          let s = def.source, let t = def.target else { return nil }
    let sv = row.properties[s]?.first.map { resolver.display($0).label }
    let tv = row.properties[t]?.first.map { resolver.display($0).label }
    guard sv != nil || tv != nil else { return nil }
    return "\(sv ?? "?") → \(tv ?? "?")"
}

private func deriveCaption(
    schema def: Ftm.SchemaDef, props: [String: [String]], resolver: RefResolver
) -> String? {
    for k in ["name", "title", "summary"] {
        if let v = props[k]?.first, !v.isEmpty { return v }
    }
    if let f = props["firstName"]?.first, let l = props["lastName"]?.first {
        return "\(f) \(l)"
    }
    return nil
}

/// A bare FtM entity object: `{ id, schema, properties }`.
private func ftmObject(_ row: FindingsStore.Finding) -> [String: Any] {
    ["id": row.id, "schema": row.schema, "properties": row.properties]
}

// MARK: - Parsing helpers

/// Parse repeated `key=value` flags into accumulated property lists.
func parseProps(_ raw: [String]) throws -> [String: [String]] {
    var out: [String: [String]] = [:]
    for item in raw {
        guard let eq = item.firstIndex(of: "=") else {
            throw SiftError("malformed -p '\(item)'", suggestion: "use key=value, e.g. -p name=\"Acme Corp\"")
        }
        let key = String(item[..<eq]).trimmingCharacters(in: .whitespaces)
        let value = String(item[item.index(after: eq)...])
        guard !key.isEmpty else {
            throw SiftError("empty property name in '\(item)'")
        }
        let coerced = Ftm.coerce(value)
        if !coerced.isEmpty { out[key, default: []].append(contentsOf: coerced) }
    }
    return out
}

/// Split comma- or repeat-delimited source aliases into a flat list.
func splitSources(_ raw: [String]) -> [String] {
    raw.flatMap { $0.split(separator: ",") }
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
}

/// Parse a `--json` payload into (schema?, raw properties). Accepts a full
/// FtM entity `{schema, properties}` or a bare properties object.
func parseJSONEntity(_ s: String) throws -> (schema: String?, props: [String: Any]) {
    guard let data = s.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
        throw SiftError("--json must be a JSON object",
                        suggestion: #"e.g. --json '{"schema":"Payment","properties":{"amount":["50000"]}}'"#)
    }
    if let props = obj["properties"] as? [String: Any] {
        return (obj["schema"] as? String, props)
    }
    var copy = obj
    copy.removeValue(forKey: "schema")
    copy.removeValue(forKey: "id")
    return (obj["schema"] as? String, copy)
}

private func pad(_ s: String, _ width: Int) -> String {
    s.count >= width ? s + " " : s + String(repeating: " ", count: width - s.count)
}
