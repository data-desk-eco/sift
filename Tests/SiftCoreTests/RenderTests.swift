import Foundation
import XCTest
@testable import SiftCore

final class RenderTests: XCTestCase {

    func testEnvelopeWrapsHeader() {
        let out = Render.envelope("search foo", "row1\nrow2")
        XCTAssertTrue(out.contains("[search foo]"))
        XCTAssertTrue(out.contains("\n\(Render.rule)\n"))
        XCTAssertTrue(out.hasSuffix("row1\nrow2"))
    }

    func testEnvelopeMarksCached() {
        let out = Render.envelope("read r1", "body", cached: true)
        XCTAssertTrue(out.hasPrefix("[read r1]  (cached)"))
    }

    func testTruncateAddsHintWhenOver() {
        let long = String(repeating: "x", count: 1600)
        let out = Render.truncate(long, maxChars: 1500)
        XCTAssertGreaterThan(out.count, 1500)
        XCTAssertTrue(out.contains("[…+100 chars truncated, pass --full]"))
    }

    func testTruncateNoOpUnderLimit() {
        XCTAssertEqual(Render.truncate("hello"), "hello")
    }

    func testShortAddsEllipsisWhenOver() {
        let out = Render.short("a very long title that exceeds the width", width: 20)
        XCTAssertEqual(out.count, 20)
        XCTAssertTrue(out.hasSuffix("\u{2026}"))
    }

    func testExtractLabelHandlesScalarsDictsArrays() {
        XCTAssertEqual(Render.extractLabel("plain"), "plain")
        XCTAssertEqual(Render.extractLabel(["label": "L"]), "L")
        XCTAssertEqual(Render.extractLabel(["name": "N"]), "N")
        XCTAssertEqual(Render.extractLabel(["id": "i-123"]), "i-123")
        XCTAssertEqual(Render.extractLabel([] as [Any]), "")
        XCTAssertEqual(Render.extractLabel(["a", "b"]), "a, b")
        XCTAssertEqual(Render.extractLabel(nil), "")
    }

    func testFirstLabelUnwrapsArray() {
        XCTAssertEqual(Render.firstLabel(["x", "y"]), "x")
        XCTAssertEqual(Render.firstLabel("x"), "x")
        XCTAssertEqual(Render.firstLabel([] as [Any]), "")
    }

    func testNormalizeSubjectStripsReplyPrefixes() {
        XCTAssertEqual(Render.normalizeSubject("Re: Fwd: hello world"), "hello world")
        XCTAssertEqual(Render.normalizeSubject("RE:RE: ping"), "ping")
        XCTAssertEqual(Render.normalizeSubject("AW: Sv: Tr: subject"), "subject")
        XCTAssertEqual(Render.normalizeSubject("plain subject"), "plain subject")
    }

    func testStripEmailAddressKeepsName() {
        XCTAssertEqual(Render.stripEmailAddress("Jane Doe <jane@example.com>"), "Jane Doe")
        XCTAssertEqual(Render.stripEmailAddress("naked@example.com"), "naked@example.com")
        XCTAssertEqual(Render.stripEmailAddress(""), "")
    }

    func testFirstEntityRefIdHandlesAllShapes() {
        XCTAssertEqual(Render.firstEntityRefId("ent-1"), "ent-1")
        XCTAssertEqual(Render.firstEntityRefId(["id": "ent-2", "schema": "Thing"]), "ent-2")
        XCTAssertEqual(Render.firstEntityRefId([["id": "ent-3"], ["id": "ent-4"]]), "ent-3")
        XCTAssertNil(Render.firstEntityRefId(nil))
        XCTAssertNil(Render.firstEntityRefId(["other": "value"]))
    }

    func testReferencedIdStringsCollects() {
        let v: Any = ["a-1", ["id": "a-2"], ["a-3", ["id": "a-4"]]]
        XCTAssertEqual(Render.referencedIdStrings(v), ["a-1", "a-2", "a-3", "a-4"])
    }

    func testTableAlignsColumns() {
        let rows: [[String]] = [["x", "1"], ["yy", "22"]]
        let out = Table.render(rows, headers: ["c1", "c2"])
        let lines = out.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines[0], "c1  c2")
        XCTAssertEqual(lines[1], "--  --")
        XCTAssertEqual(lines[2], "x   1")
        XCTAssertEqual(lines[3], "yy  22")
    }
}
