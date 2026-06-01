import Foundation
import Testing
@testable import SiftCore

@Suite struct FindingsStoreTests {

    @Test func createAssignsSequentialAliases() throws {
        let (store, dir) = try tempFindings()
        defer { try? FileManager.default.removeItem(at: dir) }

        let a = try store.create(schema: "Person", caption: "A", properties: [:], sources: [])
        let b = try store.create(schema: "Company", caption: "B", properties: [:], sources: [])
        #expect(a.alias == "f1")
        #expect(b.alias == "f2")
        #expect(a.id != b.id)
        #expect(try store.count() == 2)
    }

    @Test func propertiesAndSourcesRoundTrip() throws {
        let (store, dir) = try tempFindings()
        defer { try? FileManager.default.removeItem(at: dir) }

        let props = ["amount": ["50000"], "currency": ["USD"], "payer": ["f-x"]]
        let row = try store.create(
            schema: "Payment", caption: "p", properties: props, sources: ["src-1", "src-2"]
        )
        let fetched = try #require(try store.get(id: row.id))
        #expect(fetched.properties == props)
        #expect(fetched.sources == ["src-1", "src-2"])
        #expect(fetched.schema == "Payment")
        #expect(fetched.caption == "p")

        let byAlias = try #require(try store.byAlias("f1"))
        #expect(byAlias.id == row.id)
    }

    @Test func resolveAliasHandlesFAliasesOnly() throws {
        let (store, dir) = try tempFindings()
        defer { try? FileManager.default.removeItem(at: dir) }

        let row = try store.create(schema: "Person", caption: nil, properties: [:], sources: [])
        #expect(try store.resolveAlias("f1") == row.id)
        #expect(try store.resolveAlias("r5") == "r5")        // pass-through
        #expect(try store.resolveAlias("raw-id") == "raw-id")
        #expect(throws: SiftError.self) { try store.resolveAlias("f99") }
    }

    @Test func updatePreservesIdentityAndBumpsTimestamp() throws {
        let (store, dir) = try tempFindings()
        defer { try? FileManager.default.removeItem(at: dir) }

        let row = try store.create(
            schema: "Person", caption: "John", properties: ["name": ["John"]], sources: ["a"]
        )
        try store.update(
            id: row.id, schema: "Person", caption: "John Doe",
            properties: ["name": ["John Doe"], "nationality": ["gb"]], sources: ["b"]
        )
        let after = try #require(try store.get(id: row.id))
        #expect(after.alias == "f1")             // alias preserved
        #expect(after.n == row.n)
        #expect(after.caption == "John Doe")
        #expect(after.properties["nationality"] == ["gb"])
        #expect(after.sources == ["b"])
        #expect(after.createdAt == row.createdAt)
    }

    @Test func deleteRemovesAndReports() throws {
        let (store, dir) = try tempFindings()
        defer { try? FileManager.default.removeItem(at: dir) }

        let row = try store.create(schema: "Person", caption: nil, properties: [:], sources: [])
        #expect(try store.delete(id: row.id) == true)
        #expect(try store.delete(id: row.id) == false)   // already gone
        #expect(try store.get(id: row.id) == nil)
    }

    @Test func listFiltersBySchemaAndOrders() throws {
        let (store, dir) = try tempFindings()
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = try store.create(schema: "Person", caption: nil, properties: [:], sources: [])
        _ = try store.create(schema: "Company", caption: nil, properties: [:], sources: [])
        _ = try store.create(schema: "Person", caption: nil, properties: [:], sources: [])

        #expect(try store.all().map(\.alias) == ["f1", "f2", "f3"])
        #expect(try store.list(schema: "Person").map(\.alias) == ["f1", "f3"])
        #expect(try store.list(schema: "Company").count == 1)
        #expect(try store.list(schema: nil).count == 3)
    }

    @Test func citingFindsBySourceId() throws {
        let (store, dir) = try tempFindings()
        defer { try? FileManager.default.removeItem(at: dir) }

        let a = try store.create(schema: "Payment", caption: nil, properties: [:], sources: ["doc-1"])
        _ = try store.create(schema: "Payment", caption: nil, properties: [:], sources: ["doc-2"])
        let cites = try store.citing(sourceId: "doc-1")
        #expect(cites.map(\.id) == [a.id])
        #expect(try store.citing(sourceId: "nope").isEmpty)
    }

    @Test func referencingFindsByPropertyValue() throws {
        let (store, dir) = try tempFindings()
        defer { try? FileManager.default.removeItem(at: dir) }

        let target = try store.create(schema: "Company", caption: nil, properties: [:], sources: [])
        let edge = try store.create(
            schema: "Ownership", caption: nil,
            properties: ["asset": [target.id], "percentage": ["100"]], sources: []
        )
        let refs = try store.referencing(id: target.id)
        #expect(refs.map(\.id) == [edge.id])
        #expect(try store.referencing(id: "unreferenced").isEmpty)
    }

    @Test func reopeningPreservesAliasCounter() throws {
        let (store, dir) = try tempFindings()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try store.create(schema: "Person", caption: nil, properties: [:], sources: [])

        // A second connection to the same file continues the sequence.
        let reopened = try FindingsStore(dbPath: dir.appending(path: "findings.db"))
        let next = try reopened.create(schema: "Person", caption: nil, properties: [:], sources: [])
        #expect(next.alias == "f2")
    }
}
