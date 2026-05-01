import Foundation
import XCTest
@testable import SiftCore

final class ReportTests: XCTestCase {

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

    func testSubstituteAliasesLinksProseOnly() throws {
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
        XCTAssertEqual(counts.linked, 2)
        XCTAssertTrue(out.contains("https://aleph.example.org/entities/ent-A"))
        XCTAssertTrue(out.contains("https://aleph.example.org/entities/ent-B"))
        XCTAssertTrue(out.contains("r99 in code block"))
        XCTAssertTrue(out.contains("<code>r88</code>"))
    }

    func testUnresolvedAliasIsCounted() throws {
        let (store, dir) = try storeWithAliases()
        defer { try? FileManager.default.removeItem(at: dir) }

        let html = "<p>Mentions r1 and r999.</p>"
        var counts = Report.Counts()
        let out = Report.substituteAliases(
            html: html, store: store,
            defaultServer: "https://aleph.example.org",
            counts: &counts
        )
        XCTAssertEqual(counts.linked, 1)
        XCTAssertEqual(counts.unresolved, 1)
        XCTAssertTrue(out.contains("r999"))
    }

    func testAliasLinkURLStripsApiPath() {
        let link = Report.AliasLink(
            alias: "r1", entityId: "ent-A",
            schema: "Organization", name: "Acme"
        )
        XCTAssertEqual(
            link.url(server: "https://aleph.example.org/api/2"),
            "https://aleph.example.org/entities/ent-A"
        )
        XCTAssertEqual(
            link.url(server: "https://aleph.example.org/"),
            "https://aleph.example.org/entities/ent-A"
        )
        XCTAssertNil(link.url(server: nil))
    }

    func testRenderHTMLEndToEnd() throws {
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
        XCTAssertEqual(result.counts.linked, 2)
        XCTAssertTrue(result.html.contains("<title>test</title>"))
        XCTAssertTrue(result.html.contains("https://aleph.example.org/entities/ent-A"))
        XCTAssertTrue(result.html.contains("r88 in fenced code"))
    }
}
