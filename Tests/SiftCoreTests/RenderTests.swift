import Foundation
import Testing
@testable import SiftCore

@Suite struct RenderTests {

    @Test func envelopeWrapsHeader() {
        let out = Render.envelope("search foo", "row1\nrow2")
        #expect(out.contains("[search foo]"))
        #expect(out.contains("\n\(Render.rule)\n"))
        #expect(out.hasSuffix("row1\nrow2"))
    }

    @Test func envelopeMarksCached() {
        let out = Render.envelope("read r1", "body", cached: true)
        #expect(out.hasPrefix("[read r1]  (cached)"))
    }

    @Test func truncateAddsHintWhenOver() {
        let long = String(repeating: "x", count: 1600)
        let out = Render.truncate(long, maxChars: 1500)
        #expect(out.count > 1500)
        #expect(out.contains("[…+100 chars truncated, pass --full]"))
    }

    @Test func truncateNoOpUnderLimit() {
        #expect(Render.truncate("hello") == "hello")
    }

    @Test func shortAddsEllipsisWhenOver() {
        let out = Render.short("a very long title that exceeds the width", width: 20)
        #expect(out.count == 20)
        #expect(out.hasSuffix("\u{2026}"))
    }

    @Test func extractLabelHandlesScalarsDictsArrays() {
        #expect(Render.extractLabel("plain") == "plain")
        #expect(Render.extractLabel(["label": "L"]) == "L")
        #expect(Render.extractLabel(["name": "N"]) == "N")
        #expect(Render.extractLabel(["id": "i-123"]) == "i-123")
        #expect(Render.extractLabel([] as [Any]) == "")
        #expect(Render.extractLabel(["a", "b"]) == "a, b")
        #expect(Render.extractLabel(nil) == "")
    }

    @Test func firstLabelUnwrapsArray() {
        #expect(Render.firstLabel(["x", "y"]) == "x")
        #expect(Render.firstLabel("x") == "x")
        #expect(Render.firstLabel([] as [Any]) == "")
    }

    @Test func normalizeSubjectStripsReplyPrefixes() {
        #expect(Render.normalizeSubject("Re: Fwd: hello world") == "hello world")
        #expect(Render.normalizeSubject("RE:RE: ping") == "ping")
        #expect(Render.normalizeSubject("AW: Sv: Tr: subject") == "subject")
        #expect(Render.normalizeSubject("plain subject") == "plain subject")
    }

    @Test func stripEmailAddressKeepsName() {
        #expect(Render.stripEmailAddress("Jane Doe <jane@example.com>") == "Jane Doe")
        #expect(Render.stripEmailAddress("naked@example.com") == "naked@example.com")
        #expect(Render.stripEmailAddress("") == "")
    }

    @Test func firstEntityRefIdHandlesAllShapes() {
        #expect(Render.firstEntityRefId("ent-1") == "ent-1")
        #expect(Render.firstEntityRefId(["id": "ent-2", "schema": "Thing"]) == "ent-2")
        #expect(Render.firstEntityRefId([["id": "ent-3"], ["id": "ent-4"]]) == "ent-3")
        #expect(Render.firstEntityRefId(nil) == nil)
        #expect(Render.firstEntityRefId(["other": "value"]) == nil)
    }

    @Test func referencedIdStringsCollects() {
        let v: Any = ["a-1", ["id": "a-2"], ["a-3", ["id": "a-4"]]]
        #expect(Render.referencedIdStrings(v) == ["a-1", "a-2", "a-3", "a-4"])
    }

    @Test func tableAlignsColumns() {
        let rows: [[String]] = [["x", "1"], ["yy", "22"]]
        let out = Table.render(rows, headers: ["c1", "c2"])
        let lines = out.split(separator: "\n").map(String.init)
        #expect(lines[0] == "c1  c2")
        #expect(lines[1] == "--  --")
        #expect(lines[2] == "x   1")
        #expect(lines[3] == "yy  22")
    }
}
