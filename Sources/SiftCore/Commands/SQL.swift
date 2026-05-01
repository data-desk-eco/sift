import Foundation
import SQLite3

public struct SQLInput: Sendable {
    public var query: String
    public init(query: String) { self.query = query }
}

let sqlMaxRows = 100

public func runSQL(store: Store, input: SQLInput) throws -> String {
    let q = input.query.trimmingCharacters(in: .whitespacesAndNewlines)
    if q.isEmpty {
        throw SiftError(
            "sql requires a query",
            suggestion: "sift sql \"select alias, n from aliases order by n desc limit 5\""
        )
    }

    // Open a fresh read-only connection so writes can't slip through
    // regardless of the query text.
    let uri = "file:\(store.dbPath.path)?mode=ro"
    var ro: OpaquePointer?
    guard sqlite3_open_v2(uri, &ro, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
        throw SiftError("sqlite: couldn't open \(store.dbPath.path) read-only")
    }
    defer { sqlite3_close(ro) }

    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(ro, q, -1, &stmt, nil) == SQLITE_OK else {
        let msg = String(cString: sqlite3_errmsg(ro))
        throw SiftError("sqlite error: \(msg)", suggestion: "see SKILL.md for the cache schema")
    }
    defer { sqlite3_finalize(stmt) }

    let columnCount = sqlite3_column_count(stmt)
    if columnCount == 0 {
        // Write-side statement (DELETE / UPDATE / INSERT). Step it once
        // so SQLite reports SQLITE_READONLY rather than silently no-oping.
        let rc = sqlite3_step(stmt)
        if rc != SQLITE_DONE {
            let msg = String(cString: sqlite3_errmsg(ro))
            throw SiftError(
                "sqlite error: \(msg)",
                suggestion: "the cache DB is opened read-only; DML and DDL aren't allowed"
            )
        }
        return Render.envelope("sql", "(query produced no result set)")
    }
    var headers: [String] = []
    for i in 0..<columnCount {
        headers.append(String(cString: sqlite3_column_name(stmt, i)))
    }

    var rows: [[String]] = []
    var truncated = 0
    while sqlite3_step(stmt) == SQLITE_ROW {
        if rows.count >= sqlMaxRows { truncated += 1; continue }
        var row: [String] = []
        for i in 0..<columnCount {
            let v: String
            switch sqlite3_column_type(stmt, i) {
            case SQLITE_NULL:    v = ""
            case SQLITE_INTEGER: v = String(sqlite3_column_int64(stmt, i))
            case SQLITE_FLOAT:   v = String(sqlite3_column_double(stmt, i))
            default:
                if let cstr = sqlite3_column_text(stmt, i) {
                    v = String(cString: cstr)
                } else {
                    v = ""
                }
            }
            row.append(Render.short(v, width: 80))
        }
        rows.append(row)
    }

    if rows.isEmpty {
        return Render.envelope("sql", "(0 rows)\ncolumns: " + headers.joined(separator: ", "))
    }
    var body = Table.render(rows, headers: headers) + "\n\n\(rows.count) row(s)"
    if truncated > 0 {
        body += "\n[+\(truncated) more rows truncated — add LIMIT to your query to scope the result]"
    }
    return Render.envelope("sql", body)
}
