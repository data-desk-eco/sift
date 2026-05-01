import Foundation
import SQLite3

public struct RecallInput: Sendable {
    public var collection: String?
    public var schema: String?
    public var limit: Int
    public init(collection: String? = nil, schema: String? = nil, limit: Int = 15) {
        self.collection = collection; self.schema = schema
        self.limit = max(1, min(50, limit))
    }
}

public func runRecall(store: Store, input: RecallInput) throws -> String {
    var whereClauses: [String] = []
    var bindings: [String] = []
    if let c = input.collection {
        whereClauses.append("collection_id=?")
        bindings.append(c)
    }
    if let s = input.schema {
        whereClauses.append("schema=?")
        bindings.append(s)
    }
    let whereSql = whereClauses.isEmpty ? "" : " WHERE " + whereClauses.joined(separator: " AND ")

    let total = try queryInt(store: store,
        sql: "SELECT COUNT(*) FROM entities\(whereSql)", binds: bindings)
    let fullBodyWhere = whereClauses.isEmpty
        ? " WHERE has_full_body=1"
        : whereSql + " AND has_full_body=1"
    let fullBodies = try queryInt(store: store,
        sql: "SELECT COUNT(*) FROM entities\(fullBodyWhere)", binds: bindings)
    let edgeCount = try queryInt(store: store,
        sql: "SELECT COUNT(*) FROM edges", binds: [])

    var out: [String] = []
    var scope: [String] = []
    if let c = input.collection { scope.append("--collection \(c)") }
    if let s = input.schema     { scope.append("--schema \(s)") }
    let scopeLabel = scope.isEmpty ? "all" : scope.joined(separator: "  ")
    out.append("\(total) entities (\(fullBodies) with full body), \(edgeCount) cached edges  [\(scopeLabel)]")

    let schemaRows = try queryRows(
        store: store,
        sql: "SELECT schema, COUNT(*) AS n FROM entities\(whereSql) GROUP BY schema ORDER BY n DESC LIMIT \(input.limit)",
        binds: bindings
    )
    if !schemaRows.isEmpty {
        out.append("")
        out.append("## by schema")
        let rows: [[String]] = schemaRows.map {
            [$0[0] ?? "?", $0[1] ?? "0"]
        }
        out.append(Table.render(rows, headers: ["schema", "count"]))
    }

    var degreeSql = """
        SELECT e.id AS id, e.schema AS schema, e.name AS name, e.caption AS caption,
               COALESCE(o.n, 0) + COALESCE(i.n, 0) AS degree
          FROM entities e
          LEFT JOIN (SELECT src_id AS id, COUNT(*) AS n FROM edges GROUP BY src_id) o ON o.id = e.id
          LEFT JOIN (SELECT dst_id AS id, COUNT(*) AS n FROM edges GROUP BY dst_id) i ON i.id = e.id
        """
    if !whereClauses.isEmpty {
        degreeSql += " WHERE " + whereClauses.map { "e.\($0)" }.joined(separator: " AND ")
    }
    degreeSql += " ORDER BY degree DESC, e.updated_at DESC LIMIT \(input.limit)"
    let degreeRows = try queryRows(store: store, sql: degreeSql, binds: bindings)
    var degRows: [[String]] = []
    for r in degreeRows {
        let degree = Int(r[4] ?? "0") ?? 0
        if degree == 0 { continue }
        let id = r[0] ?? ""
        let alias = (try store.aliasFor(id)) ?? "-"
        let nm = r[2] ?? r[3] ?? String(id.prefix(10))
        let schema = r[1] ?? "?"
        degRows.append([alias, schema, Render.short(nm, width: 50), String(degree)])
    }
    if !degRows.isEmpty {
        out.append("")
        out.append("## top by degree (in+out edges)")
        out.append(Table.render(degRows, headers: ["alias", "schema", "name", "degree"]))
    }

    let recentRows = try queryRows(
        store: store,
        sql: "SELECT id, schema, name, caption, updated_at FROM entities\(whereSql) ORDER BY updated_at DESC LIMIT \(input.limit)",
        binds: bindings
    )
    var recRows: [[String]] = []
    for r in recentRows {
        let id = r[0] ?? ""
        let alias = (try store.aliasFor(id)) ?? "-"
        let nm = r[2] ?? r[3] ?? String(id.prefix(10))
        let schema = r[1] ?? "?"
        let updated = String((r[4] ?? "").prefix(19))
        recRows.append([alias, schema, Render.short(nm, width: 50), updated])
    }
    if !recRows.isEmpty {
        out.append("")
        out.append("## recently touched")
        out.append(Table.render(recRows, headers: ["alias", "schema", "name", "updated"]))
    }
    return Render.envelope("recall \(scopeLabel)", out.joined(separator: "\n"))
}

// MARK: - SQLite helpers (avoid touching Store internals)

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private func bindAll(_ stmt: OpaquePointer?, _ binds: [String]) {
    for (i, s) in binds.enumerated() {
        sqlite3_bind_text(stmt, Int32(i + 1), s, -1, sqliteTransient)
    }
}

func queryInt(store: Store, sql: String, binds: [String]) throws -> Int {
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(store.connection, sql, -1, &stmt, nil) == SQLITE_OK else {
        throw SiftError("sqlite prepare failed: \(sql)")
    }
    defer { sqlite3_finalize(stmt) }
    bindAll(stmt, binds)
    guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
    return Int(sqlite3_column_int64(stmt, 0))
}

func queryRows(store: Store, sql: String, binds: [String]) throws -> [[String?]] {
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(store.connection, sql, -1, &stmt, nil) == SQLITE_OK else {
        throw SiftError("sqlite prepare failed: \(sql)")
    }
    defer { sqlite3_finalize(stmt) }
    bindAll(stmt, binds)
    var rows: [[String?]] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
        let n = sqlite3_column_count(stmt)
        var row: [String?] = []
        for i in 0..<n {
            let type = sqlite3_column_type(stmt, i)
            switch type {
            case SQLITE_NULL: row.append(nil)
            case SQLITE_INTEGER:
                row.append(String(sqlite3_column_int64(stmt, i)))
            case SQLITE_FLOAT:
                row.append(String(sqlite3_column_double(stmt, i)))
            default:
                if let cstr = sqlite3_column_text(stmt, i) {
                    row.append(String(cString: cstr))
                } else {
                    row.append(nil)
                }
            }
        }
        rows.append(row)
    }
    return rows
}
