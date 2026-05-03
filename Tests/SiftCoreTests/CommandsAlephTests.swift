import Foundation
import Testing
@testable import SiftCore

/// All these tests share the global StubURLProtocol queue, so they
/// run serialised. Each test calls `StubURLProtocol.reset()` in the
/// suite's init to clear leftover state from a prior test.

// MARK: - sift sources

@Suite(.serialized) struct SourcesCommandTests {

    let scope = StubScope()


    @Test func listsCollections() async throws {
        StubURLProtocol.enqueueJSON("""
            {"results":[
              {"id":"col-1","label":"Pandora Papers","count":50000},
              {"id":"col-2","label":"Panama Leaks","count":12000}
            ]}
            """)
        let (store, dir) = try tempStore(label: "sources")
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = try stubbedClient()

        let out = try await runSources(
            client: client, store: store,
            input: SourcesInput(grep: nil, limit: 50)
        )
        #expect(out.contains("col-1"))
        #expect(out.contains("Pandora Papers"))
        #expect(out.contains("col-2"))
    }

    @Test func grepFiltersByLabel() async throws {
        StubURLProtocol.enqueueJSON("""
            {"results":[
              {"id":"col-1","label":"Pandora Papers","count":1},
              {"id":"col-2","label":"Other Files","count":2}
            ]}
            """)
        let (store, dir) = try tempStore(label: "sources")
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = try stubbedClient()

        let out = try await runSources(
            client: client, store: store,
            input: SourcesInput(grep: "pandora")
        )
        #expect(out.contains("Pandora"))
        #expect(!out.contains("Other Files"))
    }

    @Test func emptyResultMessage() async throws {
        StubURLProtocol.enqueueJSON(#"{"results":[]}"#)
        let (store, dir) = try tempStore(label: "sources")
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = try stubbedClient()

        let out = try await runSources(
            client: client, store: store,
            input: SourcesInput()
        )
        #expect(out.contains("none"))
    }
}

// MARK: - sift search

@Suite(.serialized) struct SearchCommandTests {

    let scope = StubScope()


    @Test func returnsResultsAndAssignsAliases() async throws {
        StubURLProtocol.enqueueJSON("""
            {
              "results": [
                {"id":"doc-1","schema":"Document",
                 "properties":{"title":["Annual Report"],"date":["2023-04-01"]}}
              ],
              "total": 1
            }
            """)
        let (store, dir) = try tempStore(label: "search")
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = try stubbedClient()

        let out = try await runSearch(
            client: client, store: store,
            input: SearchInput(query: "report")
        )
        #expect(out.contains("[search"))
        #expect(out.contains("r1"))
        #expect(out.contains("Annual Report"))
        #expect(try store.aliasFor("doc-1") == "r1")
    }

    @Test func cachedHitDoesNotRefetch() async throws {
        StubURLProtocol.enqueueJSON(#"{"results":[],"total":0}"#)
        let (store, dir) = try tempStore(label: "search")
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = try stubbedClient()

        _ = try await runSearch(
            client: client, store: store,
            input: SearchInput(query: "first call")
        )
        let countAfterFirst = StubURLProtocol.recordedRequests().count

        let out = try await runSearch(
            client: client, store: store,
            input: SearchInput(query: "first call")
        )
        let countAfterSecond = StubURLProtocol.recordedRequests().count
        #expect(countAfterSecond == countAfterFirst)  // no extra HTTP
        #expect(out.contains("cached"))
    }

    @Test func noCacheForcesRefetch() async throws {
        StubURLProtocol.enqueueJSON(#"{"results":[],"total":0}"#)
        StubURLProtocol.enqueueJSON(#"{"results":[],"total":0}"#)
        let (store, dir) = try tempStore(label: "search")
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = try stubbedClient()

        _ = try await runSearch(
            client: client, store: store,
            input: SearchInput(query: "x")
        )
        _ = try await runSearch(
            client: client, store: store,
            input: SearchInput(query: "x", noCache: true)
        )
        #expect(StubURLProtocol.recordedRequests().count == 2)
    }

    @Test func emailFilterImpliesEmailSchema() async throws {
        StubURLProtocol.enqueueJSON(#"{"results":[],"total":0}"#)
        let (store, dir) = try tempStore(label: "search")
        defer { try? FileManager.default.removeItem(at: dir) }
        // Pre-cache a person we can filter as emitter.
        try store.remember(
            eid: "p-1", schema: "Person", caption: nil, name: "Jane",
            properties: nil, collectionId: nil, server: nil
        )
        _ = try store.assignAlias("p-1")
        let client = try stubbedClient()

        _ = try await runSearch(
            client: client, store: store,
            input: SearchInput(query: "x", emitter: "r1")
        )
        let url = StubURLProtocol.recordedRequests().first
        let q = url?.query ?? ""
        #expect(q.contains("filter:properties.emitters=p-1"))
    }
}

// MARK: - sift read

@Suite(.serialized) struct ReadCommandTests {

    let scope = StubScope()


    @Test func fetchesAndRendersBody() async throws {
        StubURLProtocol.enqueueJSON("""
            {
              "id":"doc-1","schema":"Document",
              "properties":{
                "title":["Annual Report"],
                "bodyText":["The full report body goes here."]
              }
            }
            """)
        let (store, dir) = try tempStore(label: "read")
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = try stubbedClient()
        // Seed an alias so we can ask for r1.
        try store.remember(
            eid: "doc-1", schema: "Document", caption: nil, name: nil,
            properties: nil, collectionId: nil, server: nil
        )
        _ = try store.assignAlias("doc-1")

        let out = try await runRead(
            client: client, store: store, input: ReadInput(alias: "r1")
        )
        #expect(out.contains("doc-1"))
        #expect(out.contains("Document"))
        #expect(out.contains("full report body"))
    }

    @Test func rawDumpsJSONShape() async throws {
        StubURLProtocol.enqueueJSON(#"{"id":"doc-1","schema":"Document","properties":{}}"#)
        let (store, dir) = try tempStore(label: "read")
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = try stubbedClient()
        try store.remember(
            eid: "doc-1", schema: "Document", caption: nil, name: nil,
            properties: nil, collectionId: nil, server: nil
        )
        _ = try store.assignAlias("doc-1")

        let out = try await runRead(
            client: client, store: store,
            input: ReadInput(alias: "r1", raw: true)
        )
        #expect(out.contains("\"id\":\"doc-1\"") || out.contains("\"id\" : \"doc-1\""))
        #expect(out.contains("--raw"))
    }

    @Test func usesCacheWhenFullBodyAlreadyStored() async throws {
        let (store, dir) = try tempStore(label: "read")
        defer { try? FileManager.default.removeItem(at: dir) }
        // Pre-cache a document with full body — read should not make
        // an HTTP call.
        try store.remember(
            eid: "doc-1", schema: "Document", caption: "Cached",
            name: "Cached Doc",
            properties: ["bodyText": ["Local body."]],
            collectionId: nil, server: nil, fullBody: true
        )
        _ = try store.assignAlias("doc-1")
        let client = try stubbedClient()

        let out = try await runRead(
            client: client, store: store, input: ReadInput(alias: "r1")
        )
        #expect(out.contains("from cache"))
        #expect(out.contains("Local body."))
        #expect(StubURLProtocol.recordedRequests().isEmpty)
    }

    @Test func unknownAliasErrors() async throws {
        let (store, dir) = try tempStore(label: "read")
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = try stubbedClient()
        await #expect(throws: SiftError.self) {
            _ = try await runRead(
                client: client, store: store, input: ReadInput(alias: "r99")
            )
        }
    }
}

// MARK: - sift expand

@Suite(.serialized) struct ExpandCommandTests {

    let scope = StubScope()


    @Test func partyEntityReturnsCountsOnly() async throws {
        StubURLProtocol.enqueueJSON("""
            {"results":[
              {"property":"emails","count":42,"entities":[]},
              {"property":"mentions","count":7,"entities":[]}
            ]}
            """)
        let (store, dir) = try tempStore(label: "expand")
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.remember(
            eid: "p-1", schema: "Person", caption: nil, name: "Jane",
            properties: nil, collectionId: nil, server: nil
        )
        _ = try store.assignAlias("p-1")
        let client = try stubbedClient()

        let out = try await runExpand(
            client: client, store: store, input: ExpandInput(alias: "r1")
        )
        #expect(out.contains("reverse-property counts"))
        #expect(out.contains("emails"))
        #expect(out.contains("42"))
    }

    @Test func documentEntityListsRelated() async throws {
        StubURLProtocol.enqueueJSON("""
            {"results":[
              {"property":"mentions","count":2,
               "entities":[
                 {"id":"p-1","schema":"Person","properties":{"name":["Jane"]}},
                 {"id":"o-1","schema":"Organization","properties":{"name":["Acme"]}}
               ]}
            ]}
            """)
        let (store, dir) = try tempStore(label: "expand")
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.remember(
            eid: "doc-1", schema: "Document", caption: nil, name: nil,
            properties: nil, collectionId: nil, server: nil
        )
        _ = try store.assignAlias("doc-1")
        let client = try stubbedClient()

        let out = try await runExpand(
            client: client, store: store, input: ExpandInput(alias: "r1")
        )
        #expect(out.contains("mentions"))
        #expect(out.contains("Jane"))
        #expect(out.contains("Acme"))
    }
}

// MARK: - sift similar

@Suite(.serialized) struct SimilarCommandTests {

    let scope = StubScope()


    @Test func partySimilarityReturnsScoredCandidates() async throws {
        StubURLProtocol.enqueueJSON("""
            {"results":[
              {"score":0.92,"entity":{"id":"p-2","schema":"Person",
                "properties":{"name":["Jane Q. Doe"]}}},
              {"score":0.85,"entity":{"id":"p-3","schema":"Person",
                "properties":{"name":["J. Doe"]}}}
            ]}
            """)
        let (store, dir) = try tempStore(label: "similar")
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.remember(
            eid: "p-1", schema: "Person", caption: nil, name: "Jane Doe",
            properties: nil, collectionId: nil, server: nil
        )
        _ = try store.assignAlias("p-1")
        let client = try stubbedClient()

        let out = try await runSimilar(
            client: client, store: store, input: SimilarInput(alias: "r1")
        )
        #expect(out.contains("Jane Q. Doe"))
        #expect(out.contains("0.9"))
    }

    @Test func nonPartyAliasRejected() async throws {
        let (store, dir) = try tempStore(label: "similar")
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.remember(
            eid: "doc-1", schema: "Document", caption: nil, name: nil,
            properties: nil, collectionId: nil, server: nil
        )
        _ = try store.assignAlias("doc-1")
        let client = try stubbedClient()

        await #expect(throws: SiftError.self) {
            _ = try await runSimilar(
                client: client, store: store, input: SimilarInput(alias: "r1")
            )
        }
    }
}

// MARK: - sift hubs

@Suite(.serialized) struct HubsCommandTests {

    let scope = StubScope()


    @Test func reportsTopFacets() async throws {
        StubURLProtocol.enqueueJSON("""
            {
              "total": 100,
              "facets": {
                "properties.emitters": {
                  "values": [{"id":"p-1","count":50},{"id":"p-2","count":25}]
                },
                "properties.recipients": {
                  "values": [{"id":"p-3","count":40}]
                },
                "properties.peopleMentioned": {
                  "values": [{"label":"Jane Doe","count":10}]
                },
                "properties.companiesMentioned": {
                  "values": []
                }
              }
            }
            """)
        // Hubs back-fills missing party stubs — every party id triggers
        // a `/entities/<id>` GET. Queue stubs for those follow-ups.
        StubURLProtocol.enqueueJSON("""
            {"id":"p-1","schema":"Person","properties":{"name":["Alice"]}}
            """)
        StubURLProtocol.enqueueJSON("""
            {"id":"p-2","schema":"Person","properties":{"name":["Bob"]}}
            """)
        StubURLProtocol.enqueueJSON("""
            {"id":"p-3","schema":"Person","properties":{"name":["Carol"]}}
            """)
        let (store, dir) = try tempStore(label: "hubs")
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = try stubbedClient()

        let out = try await runHubs(
            client: client, store: store,
            input: HubsInput(query: "topic", schema: "Email")
        )
        #expect(out.contains("100"))
        #expect(out.contains("Top senders"))
        #expect(out.contains("Top recipients"))
        #expect(out.contains("Top people mentioned"))
        #expect(out.contains("Jane Doe"))
    }
}

// MARK: - sift tree

@Suite(.serialized) struct TreeCommandTests {

    let scope = StubScope()


    @Test func nonFolderAliasRejected() async throws {
        let (store, dir) = try tempStore(label: "tree")
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.remember(
            eid: "doc-1", schema: "Document", caption: nil, name: nil,
            properties: nil, collectionId: nil, server: nil
        )
        _ = try store.assignAlias("doc-1")
        let client = try stubbedClient()

        await #expect(throws: SiftError.self) {
            _ = try await runTree(
                client: client, store: store,
                input: TreeInput(alias: "r1")
            )
        }
    }

    @Test func collectionTreeRendersRoots() async throws {
        StubURLProtocol.enqueueJSON("""
            {
              "results": [
                {"id":"folder-1","schema":"Folder",
                 "properties":{"fileName":["Top Folder"]}},
                {"id":"doc-1","schema":"Document",
                 "properties":{"fileName":["Loose File"]}}
              ],
              "total": 2
            }
            """)
        let (store, dir) = try tempStore(label: "tree")
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = try stubbedClient()

        let out = try await runTree(
            client: client, store: store,
            input: TreeInput(collection: "col-1")
        )
        #expect(out.contains("collection col-1"))
        #expect(out.contains("Top Folder"))
        #expect(out.contains("Loose File"))
    }

    @Test func emptyArgsErrors() async throws {
        let (store, dir) = try tempStore(label: "tree")
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = try stubbedClient()
        await #expect(throws: SiftError.self) {
            _ = try await runTree(
                client: client, store: store,
                input: TreeInput()  // neither alias nor collection
            )
        }
    }
}

// MARK: - sift browse

@Suite(.serialized) struct BrowseCommandTests {

    let scope = StubScope()


    @Test func folderEntityListsDirectChildren() async throws {
        // /entities/folder-1/ is what runBrowse fetches first via
        // collectionOf — but for a known folder it goes straight to
        // scanSubtree, which calls /entities (paginated).
        StubURLProtocol.enqueueJSON("""
            {
              "results": [
                {"id":"doc-1","schema":"Document",
                 "properties":{"name":["File A"],
                  "parent":[{"id":"folder-1","schema":"Folder"}],
                  "ancestors":["folder-1"]}},
                {"id":"doc-2","schema":"Document",
                 "properties":{"name":["File B"],
                  "parent":[{"id":"folder-1","schema":"Folder"}],
                  "ancestors":["folder-1"]}}
              ],
              "total": 2
            }
            """)
        let (store, dir) = try tempStore(label: "browse")
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.remember(
            eid: "folder-1", schema: "Folder", caption: nil, name: "Root",
            properties: nil, collectionId: "col-1", server: nil
        )
        _ = try store.assignAlias("folder-1")
        let client = try stubbedClient()

        let out = try await runBrowse(
            client: client, store: store,
            input: BrowseInput(alias: "r1")
        )
        #expect(out.contains("folder:"))
        #expect(out.contains("File A"))
        #expect(out.contains("File B"))
    }
}
