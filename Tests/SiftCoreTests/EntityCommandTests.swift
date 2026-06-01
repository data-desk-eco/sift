import Foundation
import Testing
@testable import SiftCore

@Suite struct EntityCommandTests {

    // MARK: - create

    @Test func createFromProps() throws {
        let (aleph, findings, dir) = try tempStores()
        defer { try? FileManager.default.removeItem(at: dir) }

        let out = try runEntityCreate(
            findings: findings, aleph: aleph,
            input: EntityCreateInput(schema: "Company", props: ["name=Acme Holdings", "jurisdiction=cy"])
        )
        #expect(out.contains("entity create f1 Company"))
        #expect(out.contains("caption:  Acme Holdings"))
        #expect(out.contains("jurisdiction:"))
        #expect(try findings.count() == 1)
    }

    @Test func createFromJSON() throws {
        let (aleph, findings, dir) = try tempStores()
        defer { try? FileManager.default.removeItem(at: dir) }

        let out = try runEntityCreate(
            findings: findings, aleph: aleph,
            input: EntityCreateInput(json: #"{"schema":"Person","properties":{"firstName":["John"],"lastName":["Doe"]}}"#)
        )
        #expect(out.contains("f1 Person"))
        #expect(out.contains("John Doe"))   // derived caption
    }

    @Test func createWithoutSchemaThrows() throws {
        let (aleph, findings, dir) = try tempStores()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: SiftError.self) {
            _ = try runEntityCreate(
                findings: findings, aleph: aleph,
                input: EntityCreateInput(props: ["name=x"])
            )
        }
    }

    @Test func createEdgeResolvesFindingRefs() throws {
        let (aleph, findings, dir) = try tempStores()
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = try runEntityCreate(findings: findings, aleph: aleph,
            input: EntityCreateInput(schema: "Company", props: ["name=Acme"]))
        _ = try runEntityCreate(findings: findings, aleph: aleph,
            input: EntityCreateInput(schema: "Person", props: ["name=John Doe"]))
        let out = try runEntityCreate(findings: findings, aleph: aleph,
            input: EntityCreateInput(schema: "Payment",
                props: ["payer=f1", "beneficiary=f2", "amount=50000"]))

        #expect(out.contains("Acme → John Doe"))      // edge caption from refs
        #expect(out.contains("payer:"))
        #expect(out.contains("f1 Acme"))

        // Stored values are resolved ids, not the aliases.
        let payment = try #require(try findings.byAlias("f3"))
        let f1 = try #require(try findings.byAlias("f1"))
        #expect(payment.properties["payer"] == [f1.id])
    }

    @Test func sourceResolvesAlephAlias() throws {
        let (aleph, findings, dir) = try tempStores()
        defer { try? FileManager.default.removeItem(at: dir) }
        try aleph.remember(eid: "doc-1", schema: "Document", caption: "Memo",
                           name: "Memo", properties: nil, collectionId: nil, server: nil)
        let r = try aleph.assignAlias("doc-1")     // r1

        let out = try runEntityCreate(findings: findings, aleph: aleph,
            input: EntityCreateInput(schema: "Person", props: ["name=Jane"], sources: [r]))
        #expect(out.contains("sources:"))
        #expect(out.contains("\(r) Memo"))

        let row = try #require(try findings.byAlias("f1"))
        #expect(row.sources == ["doc-1"])          // resolved to id
    }

    @Test func unknownSourceAliasThrows() throws {
        let (aleph, findings, dir) = try tempStores()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: SiftError.self) {
            _ = try runEntityCreate(findings: findings, aleph: aleph,
                input: EntityCreateInput(schema: "Person", props: ["name=x"], sources: ["r9"]))
        }
    }

    @Test func unknownPropertyEmitsNote() throws {
        let (aleph, findings, dir) = try tempStores()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = try runEntityCreate(findings: findings, aleph: aleph,
            input: EntityCreateInput(schema: "Person", props: ["name=Jane", "favouriteColour=blue"]))
        #expect(out.contains("note:"))
        #expect(out.contains("favouriteColour"))
    }

    // MARK: - edit

    @Test func editSetsAndRemovesProps() throws {
        let (aleph, findings, dir) = try tempStores()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try runEntityCreate(findings: findings, aleph: aleph,
            input: EntityCreateInput(schema: "Payment", props: ["amount=50000", "currency=USD"]))

        _ = try runEntityEdit(findings: findings, aleph: aleph,
            input: EntityEditInput(alias: "f1", props: ["amount=75000"], removeProps: ["currency"]))

        let row = try #require(try findings.byAlias("f1"))
        #expect(row.properties["amount"] == ["75000"])
        #expect(row.properties["currency"] == nil)
    }

    @Test func editJSONReplacesProperties() throws {
        let (aleph, findings, dir) = try tempStores()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try runEntityCreate(findings: findings, aleph: aleph,
            input: EntityCreateInput(schema: "Person", props: ["name=John", "nationality=gb"]))

        _ = try runEntityEdit(findings: findings, aleph: aleph,
            input: EntityEditInput(alias: "f1", json: #"{"properties":{"name":["Jane"]}}"#))

        let row = try #require(try findings.byAlias("f1"))
        #expect(row.properties["name"] == ["Jane"])
        #expect(row.properties["nationality"] == nil)   // replaced wholesale
    }

    @Test func editKeepsSourcesUnlessGiven() throws {
        let (aleph, findings, dir) = try tempStores()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try runEntityCreate(findings: findings, aleph: aleph,
            input: EntityCreateInput(schema: "Person", props: ["name=John"], sources: ["raw-src"]))

        // nil sources → unchanged
        _ = try runEntityEdit(findings: findings, aleph: aleph,
            input: EntityEditInput(alias: "f1", props: ["nationality=gb"]))
        #expect(try findings.byAlias("f1")?.sources == ["raw-src"])

        // empty sources → cleared
        _ = try runEntityEdit(findings: findings, aleph: aleph,
            input: EntityEditInput(alias: "f1", sources: []))
        #expect(try findings.byAlias("f1")?.sources == [])
    }

    // MARK: - delete

    @Test func deleteBlockedWhenReferencedThenForced() throws {
        let (aleph, findings, dir) = try tempStores()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try runEntityCreate(findings: findings, aleph: aleph,
            input: EntityCreateInput(schema: "Company", props: ["name=Acme"]))
        _ = try runEntityCreate(findings: findings, aleph: aleph,
            input: EntityCreateInput(schema: "Ownership", props: ["asset=f1", "percentage=100"]))

        #expect(throws: SiftError.self) {
            _ = try runEntityDelete(findings: findings, aleph: aleph,
                input: EntityDeleteInput(alias: "f1"))
        }
        let out = try runEntityDelete(findings: findings, aleph: aleph,
            input: EntityDeleteInput(alias: "f1", force: true))
        #expect(out.contains("deleted f1"))
        #expect(out.contains("still referenced by f2"))
        #expect(try findings.byAlias("f1") == nil)
    }

    // MARK: - list / show

    @Test func listEmptyAndPopulated() throws {
        let (aleph, findings, dir) = try tempStores()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try runEntityList(findings: findings, aleph: aleph, input: EntityListInput())
            .contains("no findings yet"))

        _ = try runEntityCreate(findings: findings, aleph: aleph,
            input: EntityCreateInput(schema: "Person", props: ["name=Jane Roe"]))
        let out = try runEntityList(findings: findings, aleph: aleph, input: EntityListInput())
        #expect(out.contains("entity list (1)"))
        #expect(out.contains("f1"))
        #expect(out.contains("Jane Roe"))
    }

    @Test func listJSONIsValidFtm() throws {
        let (aleph, findings, dir) = try tempStores()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try runEntityCreate(findings: findings, aleph: aleph,
            input: EntityCreateInput(schema: "Person", props: ["name=Jane"]))

        let out = try runEntityList(findings: findings, aleph: aleph, input: EntityListInput(json: true))
        let body = out.split(separator: "\n").dropFirst(2).joined(separator: "\n")
        let data = try #require(body.data(using: .utf8))
        let arr = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        #expect(arr.count == 1)
        #expect(arr[0]["schema"] as? String == "Person")
        #expect(arr[0]["properties"] != nil)
        #expect((arr[0]["id"] as? String)?.hasPrefix("f-") == true)
    }

    @Test func showUnknownAliasThrows() throws {
        let (aleph, findings, dir) = try tempStores()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: SiftError.self) {
            _ = try runEntityShow(findings: findings, aleph: aleph, input: EntityShowInput(alias: "f7"))
        }
    }

    // MARK: - schemas

    @Test func schemasListAndDetail() {
        let list = runEntitySchemas(name: nil)
        #expect(list.contains("Person"))
        #expect(list.contains("edges:"))
        #expect(list.contains("Payment"))

        let detail = runEntitySchemas(name: "payment")
        #expect(detail.contains("edge: payer → beneficiary"))
        #expect(detail.contains("(ref)"))

        #expect(runEntitySchemas(name: "Nope").contains("unknown schema"))
    }

    // MARK: - parsing helpers

    @Test func parsePropsAccumulatesAndValidates() throws {
        let parsed = try parseProps(["a=1", "a=2", "b=x"])
        #expect(parsed["a"] == ["1", "2"])
        #expect(parsed["b"] == ["x"])
        #expect(throws: SiftError.self) { _ = try parseProps(["noequals"]) }
        #expect(throws: SiftError.self) { _ = try parseProps(["=novalue"]) }
    }

    @Test func splitSourcesFlattens() {
        #expect(splitSources(["r1,r2", " r3 "]) == ["r1", "r2", "r3"])
        #expect(splitSources([]) == [])
    }

    // MARK: - read surfacing

    @Test func readShowsFindingsThatCiteEntity() async throws {
        let (aleph, findings, dir) = try tempStores()
        defer { try? FileManager.default.removeItem(at: dir) }
        // A fully-cached Aleph entity so read() hits the cache, no network.
        try aleph.remember(eid: "doc-1", schema: "Email", caption: "Memo", name: "Memo",
                           properties: ["bodyText": ["the body"]],
                           collectionId: nil, server: nil, fullBody: true)
        let r = try aleph.assignAlias("doc-1")
        _ = try runEntityCreate(findings: findings, aleph: aleph,
            input: EntityCreateInput(schema: "Payment", props: ["amount=1"], sources: [r]))

        let client = try stubbedClient()
        let out = try await runRead(
            client: client, store: aleph, input: ReadInput(alias: r), findings: findings
        )
        #expect(out.contains("findings: f1 Payment"))
    }

    @Test func readWithoutFindingsStoreOmitsLine() async throws {
        let (aleph, _, dir) = try tempStores()
        defer { try? FileManager.default.removeItem(at: dir) }
        try aleph.remember(eid: "doc-1", schema: "Email", caption: "Memo", name: "Memo",
                           properties: ["bodyText": ["the body"]],
                           collectionId: nil, server: nil, fullBody: true)
        let r = try aleph.assignAlias("doc-1")
        let client = try stubbedClient()
        let out = try await runRead(client: client, store: aleph, input: ReadInput(alias: r))
        #expect(!out.contains("findings:"))
    }
}
