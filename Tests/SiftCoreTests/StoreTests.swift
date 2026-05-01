import Foundation
import XCTest
@testable import SiftCore

final class StoreTests: XCTestCase {

    private func tempStore() throws -> (Store, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "sift-store-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try Store(dbPath: dir.appending(path: "test.sqlite"))
        return (store, dir)
    }

    func testAliasAssignmentIsStable() throws {
        let (store, dir) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try store.remember(
            eid: "ent-1", schema: "Thing", caption: nil, name: "Thing One",
            properties: nil, collectionId: nil, server: nil, fullBody: false
        )
        XCTAssertEqual(try store.assignAlias("ent-1"), "r1")
        XCTAssertEqual(try store.assignAlias("ent-1"), "r1")  // idempotent

        try store.remember(
            eid: "ent-2", schema: "Thing", caption: nil, name: "Thing Two",
            properties: nil, collectionId: nil, server: nil, fullBody: false
        )
        XCTAssertEqual(try store.assignAlias("ent-2"), "r2")
    }

    func testResolveAliasRoundTrip() throws {
        let (store, dir) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try store.remember(
            eid: "ent-99", schema: "Thing", caption: nil, name: nil,
            properties: nil, collectionId: nil, server: nil, fullBody: false
        )
        let alias = try store.assignAlias("ent-99")
        XCTAssertEqual(try store.resolveAlias(alias), "ent-99")
    }

    func testResolveAliasFailsForUnknown() throws {
        let (store, dir) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertThrowsError(try store.resolveAlias("r99"))
    }

    func testResolveAliasPassesThroughNonAliasIds() throws {
        let (store, dir) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertEqual(try store.resolveAlias("ent-abc"), "ent-abc")
    }

    func testCacheRoundTrip() throws {
        let (store, dir) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let key = try Store.cacheKey(command: "search", args: ["q": "acme"])
        let payload: [String: Any] = ["results": [["id": "ent-1"]], "total": 1]
        try store.cacheSet(key, payload)
        let hit = try store.cacheGet(key)
        XCTAssertEqual(hit?["total"] as? Int, 1)
    }

    func testSeeEntityIngestsNestedRefs() throws {
        let (store, dir) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let entity: [String: Any] = [
            "id": "doc-1",
            "schema": "Document",
            "properties": [
                "name": ["Annual Report"],
                "mentions": [
                    ["id": "person-1", "schema": "Person",
                     "properties": ["name": ["Jane Doe"]]],
                    ["id": "org-1", "schema": "Organization",
                     "properties": ["name": ["Acme Corp"]]],
                ],
            ],
        ]
        let alias = try seeEntity(
            store: store, entity: entity,
            server: "test", collectionId: "col-1", fullBody: true
        )
        XCTAssertEqual(alias, "r1")
        XCTAssertEqual(try store.aliasFor("person-1"), "r2")
        XCTAssertEqual(try store.aliasFor("org-1"), "r3")
        let stub = try store.getEntity("doc-1")
        XCTAssertEqual(stub?.hasFullBody, true)
        XCTAssertEqual(stub?.collectionId, "col-1")
    }
}
