import Foundation
import Testing
@testable import SiftCore

@Suite struct StoreTests {

    private func tempStore() throws -> (Store, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "sift-store-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try Store(dbPath: dir.appending(path: "test.sqlite"))
        return (store, dir)
    }

    @Test func aliasAssignmentIsStable() throws {
        let (store, dir) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try store.remember(
            eid: "ent-1", schema: "Thing", caption: nil, name: "Thing One",
            properties: nil, collectionId: nil, server: nil, fullBody: false
        )
        #expect(try store.assignAlias("ent-1") == "r1")
        #expect(try store.assignAlias("ent-1") == "r1")  // idempotent

        try store.remember(
            eid: "ent-2", schema: "Thing", caption: nil, name: "Thing Two",
            properties: nil, collectionId: nil, server: nil, fullBody: false
        )
        #expect(try store.assignAlias("ent-2") == "r2")
    }

    @Test func resolveAliasRoundTrip() throws {
        let (store, dir) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try store.remember(
            eid: "ent-99", schema: "Thing", caption: nil, name: nil,
            properties: nil, collectionId: nil, server: nil, fullBody: false
        )
        let alias = try store.assignAlias("ent-99")
        #expect(try store.resolveAlias(alias) == "ent-99")
    }

    @Test func resolveAliasFailsForUnknown() throws {
        let (store, dir) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: SiftError.self) { try store.resolveAlias("r99") }
    }

    @Test func resolveAliasPassesThroughNonAliasIds() throws {
        let (store, dir) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try store.resolveAlias("ent-abc") == "ent-abc")
    }

    @Test func cacheRoundTrip() throws {
        let (store, dir) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let key = try Store.cacheKey(command: "search", args: ["q": "acme"])
        let payload: [String: Any] = ["results": [["id": "ent-1"]], "total": 1]
        try store.cacheSet(key, payload)
        let hit = try store.cacheGet(key)
        #expect(hit?["total"] as? Int == 1)
    }

    @Test func seeEntityIngestsNestedRefs() throws {
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
        #expect(alias == "r1")
        #expect(try store.aliasFor("person-1") == "r2")
        #expect(try store.aliasFor("org-1") == "r3")
        let stub = try store.getEntity("doc-1")
        #expect(stub?.hasFullBody == true)
        #expect(stub?.collectionId == "col-1")
    }
}
