import Foundation
import SQLite3
import Testing
@testable import SiftCore

// MARK: - sift sql

@Suite struct SQLCommandTests {

    @Test func emptyQueryRejected() throws {
        let (store, dir) = try tempStore(label: "sql")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: SiftError.self) {
            _ = try runSQL(store: store, input: SQLInput(query: "  "))
        }
    }

    @Test func selectAgainstAliasesReturnsRows() throws {
        let (store, dir) = try tempStore(label: "sql")
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.remember(
            eid: "ent-1", schema: "Thing", caption: nil, name: "One",
            properties: nil, collectionId: nil, server: nil
        )
        _ = try store.assignAlias("ent-1")

        let out = try runSQL(
            store: store,
            input: SQLInput(query: "SELECT alias, n FROM aliases ORDER BY n")
        )
        #expect(out.contains("[sql]"))
        #expect(out.contains("alias"))
        #expect(out.contains("r1"))
        #expect(out.contains("1 row"))
    }

    @Test func writeStatementsRejected() throws {
        let (store, dir) = try tempStore(label: "sql")
        defer { try? FileManager.default.removeItem(at: dir) }
        // Even though a UPDATE has no result columns, the readonly
        // connection must reject it, not silently no-op.
        #expect(throws: SiftError.self) {
            _ = try runSQL(
                store: store,
                input: SQLInput(query: "DELETE FROM aliases")
            )
        }
    }

    @Test func malformedSQLRejected() throws {
        let (store, dir) = try tempStore(label: "sql")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: SiftError.self) {
            _ = try runSQL(
                store: store,
                input: SQLInput(query: "SELECT * FROM nonexistent_table")
            )
        }
    }

    @Test func truncatesPastHundredRows() throws {
        let (store, dir) = try tempStore(label: "sql")
        defer { try? FileManager.default.removeItem(at: dir) }
        for i in 1...150 {
            try store.remember(
                eid: "ent-\(i)", schema: "Thing", caption: nil, name: "n\(i)",
                properties: nil, collectionId: nil, server: nil
            )
            _ = try store.assignAlias("ent-\(i)")
        }
        let out = try runSQL(
            store: store,
            input: SQLInput(query: "SELECT alias FROM aliases")
        )
        #expect(out.contains("100 row"))
        #expect(out.contains("more rows truncated"))
    }
}

// MARK: - sift cache

@Suite struct CacheCommandTests {

    @Test func statsReportsCounts() throws {
        let (store, dir) = try tempStore(label: "cache")
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.remember(
            eid: "ent-1", schema: "Thing", caption: nil, name: nil,
            properties: nil, collectionId: nil, server: nil
        )
        _ = try store.assignAlias("ent-1")
        try store.cacheSet("k1", ["v": 1])

        let out = try runCacheStats(store: store)
        #expect(out.contains("entities"))
        #expect(out.contains("aliases"))
        #expect(out.contains("cached responses"))
        #expect(out.contains("1"))
    }

    @Test func clearAllRemovesEverything() throws {
        let (store, dir) = try tempStore(label: "cache")
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.cacheSet("k1", ["v": 1])
        try store.cacheSet("k2", ["v": 2])

        let out = try runCacheClear(
            store: store, input: CacheClearInput(olderThanDays: nil)
        )
        #expect(out.contains("cleared 2"))
        #expect(try store.cacheGet("k1") == nil)
    }

    @Test func clearOlderThanLeavesRecentEntries() throws {
        let (store, dir) = try tempStore(label: "cache")
        defer { try? FileManager.default.removeItem(at: dir) }
        // Insert one row with a synthetic-old timestamp via raw SQL.
        try store.cacheSet("recent", ["v": "fresh"])
        let oldStmt = "INSERT INTO cache VALUES ('old', '{}', '2020-01-01T00:00:00Z')"
        var pErr: UnsafeMutablePointer<CChar>?
        sqlite3_exec(store.connection, oldStmt, nil, nil, &pErr)

        let out = try runCacheClear(
            store: store, input: CacheClearInput(olderThanDays: 30)
        )
        #expect(out.contains("cleared 1"))
        #expect(try store.cacheGet("recent") != nil)
        #expect(try store.cacheGet("old") == nil)
    }
}

// MARK: - sift recall

@Suite struct RecallCommandTests {

    @Test func reportsCountsAndSchemaBreakdown() throws {
        let (store, dir) = try tempStore(label: "recall")
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.remember(
            eid: "p-1", schema: "Person", caption: nil, name: "Jane",
            properties: nil, collectionId: nil, server: nil
        )
        try store.remember(
            eid: "p-2", schema: "Person", caption: nil, name: "John",
            properties: nil, collectionId: nil, server: nil
        )
        try store.remember(
            eid: "o-1", schema: "Organization", caption: nil, name: "Acme",
            properties: nil, collectionId: nil, server: nil
        )

        let out = try runRecall(
            store: store, input: RecallInput(limit: 15)
        )
        #expect(out.contains("3 entities"))
        #expect(out.contains("by schema"))
        #expect(out.contains("Person"))
        #expect(out.contains("Organization"))
    }

    @Test func filterByCollectionScopesCounts() throws {
        let (store, dir) = try tempStore(label: "recall")
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.remember(
            eid: "a", schema: "Thing", caption: nil, name: "in",
            properties: nil, collectionId: "col-A", server: nil
        )
        try store.remember(
            eid: "b", schema: "Thing", caption: nil, name: "out",
            properties: nil, collectionId: "col-B", server: nil
        )

        let out = try runRecall(
            store: store, input: RecallInput(collection: "col-A", limit: 15)
        )
        #expect(out.contains("1 entit"))
        #expect(out.contains("col-A"))
    }
}

// MARK: - sift neighbours

@Suite struct NeighborsCommandTests {

    @Test func reportsCachedEdgesGroupedByDirection() throws {
        let (store, dir) = try tempStore(label: "neigh")
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.remember(
            eid: "p-1", schema: "Person", caption: nil, name: "Jane",
            properties: nil, collectionId: nil, server: nil
        )
        try store.remember(
            eid: "doc-1", schema: "Email", caption: nil, name: "Email",
            properties: nil, collectionId: nil, server: nil
        )
        _ = try store.assignAlias("p-1")
        _ = try store.assignAlias("doc-1")
        // doc-1 has Jane as emitter — outbound from doc-1, inbound to p-1.
        try store.recordEdges(
            srcId: "doc-1",
            properties: ["emitters": [["id": "p-1", "schema": "Person"]]]
        )

        let outFromDoc = try runNeighbors(
            store: store,
            input: NeighborsInput(alias: "r2", direction: "out")
        )
        #expect(outFromDoc.contains("emitters"))
        #expect(outFromDoc.contains("r1"))

        let outFromPerson = try runNeighbors(
            store: store,
            input: NeighborsInput(alias: "r1", direction: "in")
        )
        #expect(outFromPerson.contains("emitters"))
        #expect(outFromPerson.contains("r2"))
    }

    @Test func emptyEdgesProducesHelpfulMessage() throws {
        let (store, dir) = try tempStore(label: "neigh")
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.remember(
            eid: "p-1", schema: "Person", caption: nil, name: "Jane",
            properties: nil, collectionId: nil, server: nil
        )
        _ = try store.assignAlias("p-1")
        let out = try runNeighbors(
            store: store, input: NeighborsInput(alias: "r1")
        )
        #expect(out.contains("no cached edges"))
    }

    @Test func rejectsUnknownDirection() throws {
        let (store, dir) = try tempStore(label: "neigh")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: SiftError.self) {
            _ = try runNeighbors(
                store: store,
                input: NeighborsInput(alias: "r1", direction: "sideways")
            )
        }
    }
}

