import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Per-session SQLite store of the agent's own FollowTheMoney entities —
/// the structured findings it builds while reading Aleph. Distinct from
/// `Store`/`aleph.sqlite`, which caches *real* Aleph entities under `r`
/// aliases; findings live under their own `f` aliases (`f1`, `f2`, …) so
/// the two namespaces never collide.
///
/// Lives at `$SIFT_FINDINGS_DB` (next to `report.md` in the session dir),
/// shared across the legs of one auto run but not across sessions.
/// Connections are not Sendable — build one per task.
public final class FindingsStore {
    public let dbPath: URL
    private var db: OpaquePointer?

    public init(dbPath: URL) throws {
        self.dbPath = dbPath
        try Paths.ensure(dbPath.deletingLastPathComponent())
        guard sqlite3_open(dbPath.path, &db) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            sqlite3_close(db)
            throw SiftError("failed to open \(dbPath.path): \(msg)")
        }
        sqlite3_busy_timeout(db, 5000)
        if try currentJournalMode().lowercased() != "wal" {
            try exec("PRAGMA journal_mode=WAL")
        }
        try exec(Self.schema)
    }

    deinit { if let db { sqlite3_close(db) } }

    private static let schema = """
        CREATE TABLE IF NOT EXISTS findings (
            id TEXT PRIMARY KEY,
            n INTEGER NOT NULL UNIQUE,
            alias TEXT NOT NULL UNIQUE,
            schema TEXT NOT NULL,
            caption TEXT,
            properties TEXT NOT NULL,
            sources TEXT,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        );
        """

    // MARK: - Model

    public struct Finding: Sendable {
        public let id: String
        public let n: Int
        public let alias: String
        public let schema: String
        public let caption: String?
        public let properties: [String: [String]]
        public let sources: [String]
        public let createdAt: String
        public let updatedAt: String
    }

    // MARK: - Writes

    /// Insert a new finding, assigning the next `f` alias. The MAX(n) →
    /// INSERT pair runs under a write lock so a second writer can't mint
    /// the same alias.
    @discardableResult
    public func create(
        schema: String, caption: String?,
        properties: [String: [String]], sources: [String]
    ) throws -> Finding {
        let now = Store.isoNow()
        let id = "f-" + UUID().uuidString.lowercased()
        try exec("BEGIN IMMEDIATE")
        do {
            let n = (try maxN()) + 1
            let alias = "f\(n)"
            try execBind(
                "INSERT INTO findings VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                [
                    .text(id), .int(n), .text(alias), .text(schema),
                    .textOrNull(caption), .text(try Store.jsonString(properties)),
                    .text(try Store.jsonString(sources)), .text(now), .text(now),
                ]
            )
            try exec("COMMIT")
            return Finding(
                id: id, n: n, alias: alias, schema: schema, caption: caption,
                properties: properties, sources: sources, createdAt: now, updatedAt: now
            )
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Replace a finding's mutable fields in place (id/alias/n preserved).
    public func update(
        id: String, schema: String, caption: String?,
        properties: [String: [String]], sources: [String]
    ) throws {
        try execBind(
            """
            UPDATE findings SET schema=?, caption=?, properties=?, sources=?, updated_at=?
            WHERE id=?
            """,
            [
                .text(schema), .textOrNull(caption),
                .text(try Store.jsonString(properties)),
                .text(try Store.jsonString(sources)),
                .text(Store.isoNow()), .text(id),
            ]
        )
    }

    @discardableResult
    public func delete(id: String) throws -> Bool {
        try execBind("DELETE FROM findings WHERE id=?", [.text(id)])
        return sqlite3_changes(db) > 0
    }

    // MARK: - Reads

    public func get(id: String) throws -> Finding? {
        try one("SELECT * FROM findings WHERE id=?", [.text(id)])
    }

    public func byAlias(_ alias: String) throws -> Finding? {
        try one("SELECT * FROM findings WHERE alias=?", [.text(alias)])
    }

    /// Resolve an `f`-alias to its entity id; pass anything else through
    /// unchanged (a raw id, or an `r`-alias the caller resolves elsewhere).
    public func resolveAlias(_ aliasOrId: String) throws -> String {
        let s = aliasOrId.trimmingCharacters(in: .whitespaces)
        guard s.range(of: #"^f\d+$"#, options: .regularExpression) != nil else { return s }
        guard let row = try byAlias(s) else {
            throw SiftError(
                "unknown findings alias '\(s)'",
                suggestion: "run `sift entity list` to see your findings"
            )
        }
        return row.id
    }

    public func all() throws -> [Finding] {
        try many("SELECT * FROM findings ORDER BY n", [])
    }

    public func list(schema: String?) throws -> [Finding] {
        guard let schema, !schema.isEmpty else { return try all() }
        return try many("SELECT * FROM findings WHERE schema=? ORDER BY n", [.text(schema)])
    }

    /// Findings whose `sources` cite the given entity id — used to surface
    /// "you already noted this" inline on `sift read`.
    public func citing(sourceId: String) throws -> [Finding] {
        try all().filter { $0.sources.contains(sourceId) }
    }

    /// Findings whose properties reference the given finding id, so a
    /// delete can warn about dangling edges.
    public func referencing(id: String) throws -> [Finding] {
        try all().filter { f in f.properties.values.contains { $0.contains(id) } }
    }

    public func count() throws -> Int {
        let stmt = try prepare("SELECT COUNT(*) FROM findings")
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    // MARK: - Row mapping

    private func decode(_ row: [String: Any]) -> Finding {
        let props = (row["properties"] as? String).flatMap(Self.decodeProps) ?? [:]
        let sources = (row["sources"] as? String).flatMap(Self.decodeStrings) ?? []
        return Finding(
            id: row["id"] as? String ?? "",
            n: Int((row["n"] as? Int64) ?? 0),
            alias: row["alias"] as? String ?? "",
            schema: row["schema"] as? String ?? "",
            caption: row["caption"] as? String,
            properties: props,
            sources: sources,
            createdAt: row["created_at"] as? String ?? "",
            updatedAt: row["updated_at"] as? String ?? ""
        )
    }

    private static func decodeProps(_ json: String) -> [String: [String]]? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj.mapValues { Ftm.coerce($0) }
    }

    private static func decodeStrings(_ json: String) -> [String]? {
        guard let data = json.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [Any]
        else { return nil }
        return arr.compactMap { $0 as? String }
    }

    // MARK: - SQLite plumbing

    private func maxN() throws -> Int {
        let stmt = try prepare("SELECT MAX(n) FROM findings")
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW,
              sqlite3_column_type(stmt, 0) != SQLITE_NULL
        else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    private func one(_ sql: String, _ binds: [Store.Bind]) throws -> Finding? {
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try Store.bindAll(stmt, binds)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return decode(Store.rowDict(stmt))
    }

    private func many(_ sql: String, _ binds: [Store.Bind]) throws -> [Finding] {
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try Store.bindAll(stmt, binds)
        var out: [Finding] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(decode(Store.rowDict(stmt)))
        }
        return out
    }

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.flatMap { String(cString: $0) } ?? "sqlite exec error"
            sqlite3_free(err)
            throw SiftError("sqlite: \(msg)")
        }
    }

    private func execBind(_ sql: String, _ binds: [Store.Bind]) throws {
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try Store.bindAll(stmt, binds)
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw SiftError("sqlite step: \(msg)")
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SiftError("sqlite prepare: \(String(cString: sqlite3_errmsg(db)))")
        }
        return stmt
    }

    private func currentJournalMode() throws -> String {
        let stmt = try prepare("PRAGMA journal_mode")
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return "" }
        return Store.columnText(stmt, 0) ?? ""
    }
}
