import Foundation
import SQLite3

public struct NeighborsInput: Sendable {
    public var alias: String
    public var direction: String
    public var property: String?
    public var limit: Int
    public init(alias: String, direction: String = "both",
                property: String? = nil, limit: Int = 50) {
        self.alias = alias; self.direction = direction
        self.property = property; self.limit = max(1, limit)
    }
}

public func runNeighbors(store: Store, input: NeighborsInput) throws -> String {
    let direction = input.direction.lowercased()
    guard ["out", "in", "both"].contains(direction) else {
        throw SiftError(
            "unknown direction '\(direction)'",
            suggestion: "--direction out|in|both"
        )
    }
    let eid = try store.resolveAlias(input.alias)
    let (selfAlias, selfSchema, selfName) = try labelFor(store, eid)

    var lines: [String] = ["\(selfAlias) \(selfSchema)  \(Render.short(selfName, width: 60))"]

    func renderBlock(title: String, rows: [[String]]) {
        if rows.isEmpty { return }
        lines.append("")
        lines.append("## \(title)")
        lines.append(Table.render(rows, headers: ["property", "alias", "schema", "name"]))
    }

    if direction == "out" || direction == "both" {
        let (rows, hidden) = try collectEdges(
            store: store, isOut: true, eid: eid,
            property: input.property, perPropLimit: input.limit
        )
        renderBlock(title: "out edges (\(rows.count))", rows: rows)
        if hidden > 0 { lines.append("… \(hidden) edges hidden (raise --limit)") }
    }
    if direction == "in" || direction == "both" {
        let (rows, hidden) = try collectEdges(
            store: store, isOut: false, eid: eid,
            property: input.property, perPropLimit: input.limit
        )
        renderBlock(title: "in edges (\(rows.count))", rows: rows)
        if hidden > 0 { lines.append("… \(hidden) edges hidden (raise --limit)") }
    }
    if lines.count == 1 {
        lines.append("")
        lines.append("(no cached edges — the entity may not have been expanded yet; "
            + "try `expand` or `read` first)")
    }

    var header = "neighbours \(input.alias)"
    if let p = input.property { header += " --property \(p)" }
    if direction != "both"   { header += " --direction \(direction)" }
    return Render.envelope(header, lines.joined(separator: "\n"))
}

private func labelFor(_ store: Store, _ eid: String) throws -> (String, String, String) {
    let alias = (try store.aliasFor(eid)) ?? "-"
    let stub = try store.getEntity(eid)
    let schema = stub?.schema ?? "?"
    let name = stub?.name ?? stub?.caption ?? String(eid.prefix(10))
    return (alias, schema, name)
}

private func collectEdges(
    store: Store, isOut: Bool, eid: String,
    property: String?, perPropLimit: Int
) throws -> (rows: [[String]], hidden: Int) {
    let column = isOut ? "src_id" : "dst_id"
    let other = isOut ? "dst_id" : "src_id"
    var sql = "SELECT prop, \(other) FROM edges WHERE \(column)=?"
    if property != nil { sql += " AND prop=?" }
    sql += " ORDER BY prop, \(other)"

    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(store.connection, sql, -1, &stmt, nil) == SQLITE_OK else {
        throw SiftError("sqlite prepare failed")
    }
    defer { sqlite3_finalize(stmt) }
    sqlite3_bind_text(stmt, 1, eid, -1, sqliteTransient)
    if let p = property {
        sqlite3_bind_text(stmt, 2, p, -1, sqliteTransient)
    }

    var rows: [[String]] = []
    var perProp: [String: Int] = [:]
    var hidden = 0
    while sqlite3_step(stmt) == SQLITE_ROW {
        let prop = String(cString: sqlite3_column_text(stmt, 0))
        let otherId = String(cString: sqlite3_column_text(stmt, 1))
        perProp[prop, default: 0] += 1
        if perProp[prop]! > perPropLimit { hidden += 1; continue }
        let (a, sch, nm) = try labelFor(store, otherId)
        rows.append([prop, a, sch, Render.short(nm, width: 60)])
    }
    return (rows, hidden)
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
