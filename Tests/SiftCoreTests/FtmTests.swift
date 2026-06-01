import Foundation
import Testing
@testable import SiftCore

@Suite struct FtmTests {

    @Test func schemaLookupIsCaseTolerant() {
        #expect(Ftm.schema("Person")?.name == "Person")
        #expect(Ftm.schema("person")?.name == "Person")
        #expect(Ftm.schema("  payment  ")?.name == "Payment")
        #expect(Ftm.schema("NotAThing") == nil)
    }

    @Test func registryCoversKeySchemas() {
        let names = Set(Ftm.schemaNames)
        for s in ["Person", "Company", "Organization", "Payment", "Ownership", "BankAccount"] {
            #expect(names.contains(s))
        }
        // No duplicate names survive into the lookup map.
        #expect(Set(Ftm.registry.map(\.name)).count == Set(Ftm.schemaNames).count)
    }

    @Test func edgeSchemasDeclareEntityEndpoints() {
        for def in Ftm.registry where def.isEdge {
            let source = try! #require(def.source)
            let target = try! #require(def.target)
            #expect(def.props[source] == .entity, "\(def.name).\(source) must be an entity ref")
            #expect(def.props[target] == .entity, "\(def.name).\(target) must be an entity ref")
            #expect(def.entityProps.contains(source))
            #expect(def.entityProps.contains(target))
        }
        // Things are not edges.
        #expect(Ftm.schema("Person")?.isEdge == false)
        #expect(Ftm.schema("Payment")?.isEdge == true)
        #expect(Ftm.schema("Payment")?.source == "payer")
        #expect(Ftm.schema("Payment")?.target == "beneficiary")
    }

    @Test func coerceSquashesToStringArrays() {
        #expect(Ftm.coerce("hello") == ["hello"])
        #expect(Ftm.coerce(["a", "b"]) == ["a", "b"])
        #expect(Ftm.coerce(50000) == ["50000"])
        #expect(Ftm.coerce([["x"], "y"]) == ["x", "y"])
        #expect(Ftm.coerce("   ") == [])
        #expect(Ftm.coerce(nil) == [])
        #expect(Ftm.coerce(NSNull()) == [])
    }

    @Test func normalizeRejectsUnknownSchema() {
        #expect(throws: SiftError.self) {
            _ = try Ftm.normalize(schema: "Bogus", properties: ["name": "x"])
        }
    }

    @Test func normalizeKeepsUnknownPropWithWarning() throws {
        let n = try Ftm.normalize(
            schema: "person",
            properties: ["name": "Jane", "favouriteColour": "blue", "blank": "  "]
        )
        #expect(n.schema == "Person")                       // canonicalised
        #expect(n.properties["name"] == ["Jane"])
        #expect(n.properties["favouriteColour"] == ["blue"])  // kept
        #expect(n.properties["blank"] == nil)                 // empty dropped
        #expect(n.warnings.count == 1)
        #expect(n.warnings[0].contains("favouriteColour"))
    }

    @Test func normalizeIsDeterministic() throws {
        let props: [String: Any] = ["z": "1", "a": "2", "m": "3"]
        let first = try Ftm.normalize(schema: "Person", properties: props).warnings
        let second = try Ftm.normalize(schema: "Person", properties: props).warnings
        #expect(first == second)
    }
}
