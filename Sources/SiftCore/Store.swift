import CommonCrypto
import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// SQLite-backed store: aliases (`r1`, `r2`, …), entity blobs cached
/// in FtM shape, the response cache, and the property-edge graph. Same
/// schema as sift's Python store; one DB per session.
///
/// Connections are not Sendable. Build one per task / queue.
public final class Store {
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
        // Pragmas for sane multi-process behaviour and durability.
        try exec("PRAGMA journal_mode=WAL")
        try exec("PRAGMA foreign_keys=ON")

        try exec(Self.schema)
        try migrate()
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    private static let schema = """
        CREATE TABLE IF NOT EXISTS entities (
            id TEXT PRIMARY KEY,
            schema TEXT NOT NULL,
            caption TEXT,
            name TEXT,
            properties TEXT,
            collection_id TEXT,
            server TEXT,
            has_full_body INTEGER NOT NULL DEFAULT 0,
            first_seen TEXT NOT NULL,
            updated_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS aliases (
            alias TEXT PRIMARY KEY,
            n INTEGER NOT NULL UNIQUE,
            entity_id TEXT NOT NULL UNIQUE,
            assigned_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS cache (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL,
            set_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS edges (
            src_id TEXT NOT NULL,
            prop TEXT NOT NULL,
            dst_id TEXT NOT NULL,
            first_seen TEXT NOT NULL,
            PRIMARY KEY (src_id, prop, dst_id)
        );
        CREATE INDEX IF NOT EXISTS idx_edges_src ON edges(src_id, prop);
        CREATE INDEX IF NOT EXISTS idx_edges_dst ON edges(dst_id, prop);
        """

    private static let schemaVersion: Int = 1

    private func migrate() throws {
        let ver = try queryInt("PRAGMA user_version")
        if ver < 1 {
            // Backfill edges from any pre-existing entity blobs.
            let stmt = try prepare("SELECT id, properties, first_seen FROM entities WHERE properties IS NOT NULL")
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = Self.columnText(stmt, 0) ?? ""
                let propsJson = Self.columnText(stmt, 1) ?? ""
                let firstSeen = Self.columnText(stmt, 2) ?? Self.isoNow()
                guard let propsData = propsJson.data(using: .utf8),
                      let props = try? JSONSerialization.jsonObject(with: propsData) as? [String: Any]
                else { continue }
                for edge in Self.iterPropertyEdges(props) {
                    try insertEdgeIfMissing(src: id, prop: edge.prop, dst: edge.dst, ts: firstSeen)
                }
            }
            try exec("PRAGMA user_version = \(Self.schemaVersion)")
        }
    }

    // MARK: - Entities

    public func remember(
        eid: String,
        schema: String,
        caption: String?,
        name: String?,
        properties: [String: Any]?,
        collectionId: String?,
        server: String?,
        fullBody: Bool = false
    ) throws {
        let now = Self.isoNow()
        let propsJson: String? = try properties.map { try Self.jsonString($0) }

        let existing = try selectRow(
            "SELECT properties, collection_id, server, has_full_body FROM entities WHERE id=?",
            [.text(eid)]
        )
        if existing == nil {
            try execBind(
                """
                INSERT INTO entities VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    .text(eid), .text(schema), .textOrNull(caption), .textOrNull(name),
                    .textOrNull(propsJson), .textOrNull(collectionId), .textOrNull(server),
                    .int(fullBody ? 1 : 0), .text(now), .text(now),
                ]
            )
        } else {
            let prev = existing!
            let prevProps = prev["properties"] as? String
            let prevColl = prev["collection_id"] as? String
            let prevServer = prev["server"] as? String
            let prevFull = (prev["has_full_body"] as? Int64) ?? 0

            let newProps = (propsJson?.isEmpty == false) ? propsJson : prevProps
            let newColl = collectionId ?? prevColl
            let newServer = server ?? prevServer
            let newFull: Int = (fullBody || prevFull == 1) ? 1 : 0

            try execBind(
                """
                UPDATE entities SET
                    schema=?, caption=COALESCE(?, caption), name=COALESCE(?, name),
                    properties=?, collection_id=?, server=?, has_full_body=?,
                    updated_at=? WHERE id=?
                """,
                [
                    .text(schema), .textOrNull(caption), .textOrNull(name),
                    .textOrNull(newProps), .textOrNull(newColl), .textOrNull(newServer),
                    .int(newFull), .text(now), .text(eid),
                ]
            )
        }
    }

    public struct EntityRow: Sendable {
        public let id: String
        public let schema: String
        public let caption: String?
        public let name: String?
        public let propertiesJson: String?
        public let collectionId: String?
        public let server: String?
        public let hasFullBody: Bool
    }

    public func getEntity(_ eid: String) throws -> EntityRow? {
        guard let row = try selectRow(
            "SELECT id, schema, caption, name, properties, collection_id, server, has_full_body FROM entities WHERE id=?",
            [.text(eid)]
        ) else { return nil }
        return EntityRow(
            id: row["id"] as? String ?? eid,
            schema: row["schema"] as? String ?? "",
            caption: row["caption"] as? String,
            name: row["name"] as? String,
            propertiesJson: row["properties"] as? String,
            collectionId: row["collection_id"] as? String,
            server: row["server"] as? String,
            hasFullBody: ((row["has_full_body"] as? Int64) ?? 0) == 1
        )
    }

    public func cachedProperties(_ eid: String) throws -> [String: Any]? {
        guard let row = try selectRow(
            "SELECT properties FROM entities WHERE id=?", [.text(eid)]
        ),
        let json = row["properties"] as? String,
        let data = json.data(using: .utf8)
        else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    public func hasFullBody(_ eid: String) throws -> Bool {
        guard let row = try selectRow(
            "SELECT has_full_body FROM entities WHERE id=?", [.text(eid)]
        ) else { return false }
        return ((row["has_full_body"] as? Int64) ?? 0) == 1
    }

    public func collectionOf(_ eid: String) throws -> String? {
        guard let row = try selectRow(
            "SELECT collection_id FROM entities WHERE id=?", [.text(eid)]
        ) else { return nil }
        return row["collection_id"] as? String
    }

    // MARK: - Edges

    public func recordEdges(srcId: String, properties: [String: Any]?) throws {
        guard let properties else { return }
        let now = Self.isoNow()
        for edge in Self.iterPropertyEdges(properties) {
            try insertEdgeIfMissing(src: srcId, prop: edge.prop, dst: edge.dst, ts: now)
        }
    }

    private func insertEdgeIfMissing(src: String, prop: String, dst: String, ts: String) throws {
        try execBind(
            "INSERT OR IGNORE INTO edges VALUES (?, ?, ?, ?)",
            [.text(src), .text(prop), .text(dst), .text(ts)]
        )
    }

    // MARK: - Aliases

    public func aliasFor(_ eid: String) throws -> String? {
        try selectRow(
            "SELECT alias FROM aliases WHERE entity_id=?", [.text(eid)]
        )?["alias"] as? String
    }

    public func assignAlias(_ eid: String) throws -> String {
        if let existing = try aliasFor(eid) { return existing }
        let row = try selectRow("SELECT MAX(n) AS m FROM aliases", [])
        let n = ((row?["m"] as? Int64) ?? 0) + 1
        let alias = "r\(n)"
        try execBind(
            "INSERT INTO aliases VALUES (?, ?, ?, ?)",
            [.text(alias), .int(Int(n)), .text(eid), .text(Self.isoNow())]
        )
        return alias
    }

    public func resolveAlias(_ aliasOrId: String) throws -> String {
        let s = aliasOrId.trimmingCharacters(in: .whitespaces)
        if s.range(of: #"^r\d+$"#, options: .regularExpression) != nil {
            guard let row = try selectRow(
                "SELECT entity_id FROM aliases WHERE alias=?", [.text(s)]
            ),
            let eid = row["entity_id"] as? String
            else {
                throw SiftError(
                    "unknown alias '\(s)'",
                    suggestion: "run a search first or pass the raw entity id"
                )
            }
            return eid
        }
        return s
    }

    public func resolveOptional(_ aliasOrId: String?) throws -> String? {
        guard let raw = aliasOrId?.trimmingCharacters(in: .whitespaces),
              !raw.isEmpty
        else { return nil }
        if raw.range(of: #"^r\d+$"#, options: .regularExpression) != nil {
            return try resolveAlias(raw)
        }
        return raw
    }

    // MARK: - Response cache

    public func cacheGet(_ key: String) throws -> [String: Any]? {
        guard let row = try selectRow(
            "SELECT value FROM cache WHERE key=?", [.text(key)]
        ),
        let json = row["value"] as? String,
        let data = json.data(using: .utf8)
        else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    public func cacheSet(_ key: String, _ value: [String: Any]) throws {
        let json = try Self.jsonString(value)
        try execBind(
            "INSERT OR REPLACE INTO cache VALUES (?, ?, ?)",
            [.text(key), .text(json), .text(Self.isoNow())]
        )
    }

    public static func cacheKey(command: String, args: [String: Any]) throws -> String {
        let payload: [String: Any] = ["command": command, "args": args]
        let json = try jsonString(payload, sortedKeys: true)
        let data = json.data(using: .utf8) ?? Data()
        return data.sha256Hex().prefix(16).description
    }

    // MARK: - Iterating connection (for ad-hoc reads)

    public var connection: OpaquePointer? { db }

    // MARK: - Edge iteration (mirror of Python iter_property_edges)

    struct Edge { let prop: String; let dst: String }

    static func iterPropertyEdges(_ props: [String: Any]) -> [Edge] {
        var out: [Edge] = []
        for (prop, value) in props {
            collectRefIds(prop: prop, value: value, into: &out)
        }
        return out
    }

    private static func collectRefIds(prop: String, value: Any?, into out: inout [Edge]) {
        switch value {
        case nil, is NSNull: return
        case let s as String:
            if Schemas.bareStringRefProps.contains(prop), !s.isEmpty {
                out.append(Edge(prop: prop, dst: s))
            }
        case let dict as [String: Any]:
            if let eid = dict["id"] as? String, !eid.isEmpty,
               let _ = dict["schema"] as? String {
                out.append(Edge(prop: prop, dst: eid))
            }
        case let arr as [Any]:
            for item in arr { collectRefIds(prop: prop, value: item, into: &out) }
        default:
            break
        }
    }

    // MARK: - SQLite helpers

    enum Bind {
        case text(String)
        case textOrNull(String?)
        case int(Int)
        case null
    }

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.flatMap { String(cString: $0) } ?? "sqlite exec error"
            sqlite3_free(err)
            throw SiftError("sqlite: \(msg)\nSQL: \(sql)")
        }
    }

    fileprivate func prepare(_ sql: String) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw SiftError("sqlite prepare: \(msg)\nSQL: \(sql)")
        }
        return stmt
    }

    private func execBind(_ sql: String, _ binds: [Bind]) throws {
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try Self.bindAll(stmt, binds)
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw SiftError("sqlite step: \(msg)\nSQL: \(sql)")
        }
    }

    private func selectRow(_ sql: String, _ binds: [Bind]) throws -> [String: Any]? {
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try Self.bindAll(stmt, binds)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return Self.rowDict(stmt)
    }

    private func queryInt(_ sql: String) throws -> Int {
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    static func bindAll(_ stmt: OpaquePointer?, _ binds: [Bind]) throws {
        for (i, bind) in binds.enumerated() {
            let idx = Int32(i + 1)
            switch bind {
            case .text(let s):
                sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT)
            case .textOrNull(let s):
                if let s { sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT) }
                else { sqlite3_bind_null(stmt, idx) }
            case .int(let n):
                sqlite3_bind_int64(stmt, idx, sqlite3_int64(n))
            case .null:
                sqlite3_bind_null(stmt, idx)
            }
        }
    }

    static func columnText(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard let cstr = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: cstr)
    }

    static func rowDict(_ stmt: OpaquePointer?) -> [String: Any] {
        var result: [String: Any] = [:]
        let n = sqlite3_column_count(stmt)
        for i in 0..<n {
            let name = String(cString: sqlite3_column_name(stmt, i))
            switch sqlite3_column_type(stmt, i) {
            case SQLITE_INTEGER:
                result[name] = sqlite3_column_int64(stmt, i)
            case SQLITE_FLOAT:
                result[name] = sqlite3_column_double(stmt, i)
            case SQLITE_TEXT:
                if let cstr = sqlite3_column_text(stmt, i) {
                    result[name] = String(cString: cstr)
                }
            case SQLITE_NULL:
                continue
            default:
                continue
            }
        }
        return result
    }

    // MARK: - Misc helpers

    public static func isoNow() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }

    static func jsonString(_ value: Any, sortedKeys: Bool = false) throws -> String {
        var opts: JSONSerialization.WritingOptions = []
        if sortedKeys { opts.insert(.sortedKeys) }
        let data = try JSONSerialization.data(withJSONObject: value, options: opts)
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

extension Data {
    func sha256Hex() -> String {
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(count), &hash) }
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}
