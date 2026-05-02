import Foundation
import Testing
@testable import SiftCore

@Suite struct ReportTests {

    /// Build a fresh store seeded with two aliased entities. The temp
    /// dir is cleaned up by the test harness's per-test isolation.
    private func storeWithAliases() throws -> (Store, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "sift-report-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try Store(dbPath: dir.appending(path: "store.sqlite"))
        try store.remember(
            eid: "ent-A", schema: "Organization", caption: nil, name: "Acme",
            properties: nil, collectionId: nil, server: nil, fullBody: false
        )
        try store.remember(
            eid: "ent-B", schema: "Person", caption: nil, name: "Jane Doe",
            properties: nil, collectionId: nil, server: nil, fullBody: false
        )
        _ = try store.assignAlias("ent-A")
        _ = try store.assignAlias("ent-B")
        return (store, dir)
    }

    @Test func substituteAliasesLinksProseOnly() throws {
        let (store, dir) = try storeWithAliases()
        defer { try? FileManager.default.removeItem(at: dir) }

        let html = """
            <p>Acme is r1. Jane is r2.</p>
            <pre><code>r99 in code block</code></pre>
            <p>Inline <code>r88</code> stays as is.</p>
            """
        var counts = Report.Counts()
        let out = Report.substituteAliases(
            html: html, store: store,
            defaultServer: "https://aleph.example.org/api/2",
            counts: &counts
        )
        #expect(counts.linked == 2)
        #expect(out.contains("https://aleph.example.org/entities/ent-A"))
        #expect(out.contains("https://aleph.example.org/entities/ent-B"))
        #expect(out.contains("r99 in code block"))
        #expect(out.contains("<code>r88</code>"))
    }

    @Test func unresolvedAliasIsCounted() throws {
        let (store, dir) = try storeWithAliases()
        defer { try? FileManager.default.removeItem(at: dir) }

        let html = "<p>Mentions r1 and r999.</p>"
        var counts = Report.Counts()
        let out = Report.substituteAliases(
            html: html, store: store,
            defaultServer: "https://aleph.example.org",
            counts: &counts
        )
        #expect(counts.linked == 1)
        #expect(counts.unresolved == 1)
        #expect(out.contains("r999"))
    }

    @Test func aliasLinkURLStripsApiPath() {
        let link = Report.AliasLink(
            alias: "r1", entityId: "ent-A",
            schema: "Organization", name: "Acme"
        )
        #expect(link.url(server: "https://aleph.example.org/api/2")
                == "https://aleph.example.org/entities/ent-A")
        #expect(link.url(server: "https://aleph.example.org/")
                == "https://aleph.example.org/entities/ent-A")
        #expect(link.url(server: nil) == nil)
    }

    @Test func renderHTMLEndToEnd() throws {
        let (store, dir) = try storeWithAliases()
        defer { try? FileManager.default.removeItem(at: dir) }

        let md = """
            # Title

            Body paragraph mentions **r1** and r2.

            ```
            r88 in fenced code
            ```
            """
        let result = Report.renderHTML(
            markdown: md, store: store,
            defaultServer: "https://aleph.example.org",
            title: "test", meta: ""
        )
        #expect(result.counts.linked == 2)
        #expect(result.html.contains("<title>test</title>"))
        #expect(result.html.contains("https://aleph.example.org/entities/ent-A"))
        #expect(result.html.contains("r88 in fenced code"))
    }
}
