import Foundation
import XCTest
@testable import SiftCore

final class EventStreamTests: XCTestCase {

    func testSessionEventEmitsTruncatedId() {
        var stream = EventStream()
        let lines = stream.ingest(#"{"type":"session","id":"abcd1234defghi"}"#)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].scope, "session")
        XCTAssertEqual(lines[0].message, "abcd1234")
        XCTAssertEqual(lines[0].formatted, "[session] abcd1234")
    }

    func testToolStartShowsArgPreview() {
        var stream = EventStream()
        let lines = stream.ingest(#"{"type":"tool_execution_start","toolName":"search","args":{"query":"acme corp"}}"#)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].scope, "tool")
        XCTAssertEqual(lines[0].message, "search: acme corp")
    }

    func testToolEndOnlyEmitsOnError() {
        var stream = EventStream()
        let ok = stream.ingest(#"{"type":"tool_execution_end","toolName":"search","isError":false}"#)
        XCTAssertTrue(ok.isEmpty)
        let bad = stream.ingest(#"{"type":"tool_execution_end","toolName":"read","isError":true,"result":"unknown alias r3"}"#)
        XCTAssertEqual(bad.count, 1)
        XCTAssertEqual(bad[0].scope, "tool!")
        XCTAssertEqual(bad[0].message, "read: unknown alias r3")
    }

    func testCompactionEvents() {
        var stream = EventStream()
        let start = stream.ingest(#"{"type":"compaction_start"}"#)
        XCTAssertEqual(start.first?.formatted, "[compact] start")
        let end = stream.ingest(#"{"type":"compaction_end"}"#)
        XCTAssertEqual(end.first?.formatted, "[compact] end")
    }

    func testErrorEventTruncatesLongMessages() {
        var stream = EventStream()
        let long = String(repeating: "x", count: 250)
        let lines = stream.ingest(#"{"type":"error","message":"\#(long)"}"#)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].scope, "error")
        XCTAssertLessThanOrEqual(lines[0].message.count, 200)
    }

    func testAgentEndFlushesAccumulatedFinalText() {
        var stream = EventStream()
        _ = stream.ingest(#"{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"All done."}]}}"#)
        let lines = stream.ingest(#"{"type":"agent_end"}"#)
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].scope.isEmpty)
        XCTAssertTrue(lines[1].isFinalText)
        XCTAssertEqual(lines[1].message, "All done.")
        XCTAssertEqual(lines[2].scope, "done")
    }

    func testNonJsonLinePassesThroughAsRaw() {
        var stream = EventStream()
        let lines = stream.ingest("welp this is not json")
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].scope, "raw")
    }

    func testDebugModePassesEverythingThrough() {
        var stream = EventStream(debug: true)
        let json = #"{"type":"agent_start","extra":"info"}"#
        let lines = stream.ingest(json)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].formatted, json)
    }

    func testUnknownEventTypesAreSilent() {
        var stream = EventStream()
        let lines = stream.ingest(#"{"type":"some_future_event","data":42}"#)
        XCTAssertTrue(lines.isEmpty)
    }
}
