import Foundation
import SQLite3

public struct CacheClearInput: Sendable {
    public var olderThanDays: Int?
    public init(olderThanDays: Int? = nil) {
        self.olderThanDays = olderThanDays
    }
}

public func runCacheStats(store: Store) throws -> String {
    let dbPath = store.dbPath
    let attrs = try? FileManager.default.attributesOfItem(atPath: dbPath.path)
    let sizeBytes = (attrs?[.size] as? UInt64) ?? 0

    let entities  = try queryInt(store: store, sql: "SELECT COUNT(*) FROM entities", binds: [])
    let aliases   = try queryInt(store: store, sql: "SELECT COUNT(*) FROM aliases",  binds: [])
    let edges     = try queryInt(store: store, sql: "SELECT COUNT(*) FROM edges",    binds: [])
    let cacheRows = try queryInt(store: store, sql: "SELECT COUNT(*) FROM cache",    binds: [])
    let fullBodies = try queryInt(
        store: store,
        sql: "SELECT COUNT(*) FROM entities WHERE has_full_body=1", binds: []
    )

    let cacheAge = try queryRows(
        store: store, sql: "SELECT MIN(set_at), MAX(set_at) FROM cache", binds: []
    ).first
    let oldest = cacheAge?[0] ?? nil
    let newest = cacheAge?[1] ?? nil

    let rows: [[String]] = [
        ["db", dbPath.path],
        ["size", formatSize(sizeBytes)],
        ["entities", "\(entities) (\(fullBodies) with full body)"],
        ["aliases", String(aliases)],
        ["edges", String(edges)],
        ["cached responses", String(cacheRows)],
        ["oldest cache entry", oldest ?? "(empty)"],
        ["newest cache entry", newest ?? "(empty)"],
    ]
    return Render.envelope("cache stats", Table.render(rows, headers: ["key", "value"]))
}

public func runCacheClear(store: Store, input: CacheClearInput) throws -> String {
    let scope: String
    let deleted: Int
    if let days = input.olderThanDays {
        let cutoff = isoCutoff(daysAgo: days)
        let stmt = try prepareWriter(
            store: store,
            sql: "DELETE FROM cache WHERE set_at < ?"
        )
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, cutoff, -1, sqliteTransient)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw SiftError("sqlite: cache delete failed")
        }
        deleted = Int(sqlite3_changes(store.connection))
        scope = "older than \(days)d (cutoff \(cutoff))"
    } else {
        let stmt = try prepareWriter(store: store, sql: "DELETE FROM cache")
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw SiftError("sqlite: cache delete failed")
        }
        deleted = Int(sqlite3_changes(store.connection))
        scope = "all entries"
    }
    let entryWord = deleted == 1 ? "entry" : "entries"
    let body = "cleared \(deleted) cache \(entryWord) (\(scope))"
    return Render.envelope("cache clear", body)
}

private func prepareWriter(store: Store, sql: String) throws -> OpaquePointer? {
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(store.connection, sql, -1, &stmt, nil) == SQLITE_OK else {
        throw SiftError("sqlite prepare failed: \(sql)")
    }
    return stmt
}

private func formatSize(_ bytes: UInt64) -> String {
    var n = Double(bytes)
    let units = ["B", "KB", "MB", "GB", "TB"]
    var i = 0
    while n >= 1024, i < units.count - 1 { n /= 1024; i += 1 }
    return String(format: "%.1f %@", n, units[i])
}

private func isoCutoff(daysAgo days: Int) -> String {
    let date = Calendar(identifier: .gregorian)
        .date(byAdding: .day, value: -days, to: Date()) ?? Date()
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f.string(from: date)
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
