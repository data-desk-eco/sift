import Foundation
import Testing
@testable import SiftCore

@Suite struct EventStreamTests {

    @Test func sessionEventEmitsTruncatedId() {
        var stream = EventStream()
        let lines = stream.ingest(#"{"type":"session","id":"abcd1234defghi"}"#)
        #expect(lines.count == 1)
        #expect(lines[0].scope == "session")
        #expect(lines[0].message == "abcd1234")
        #expect(lines[0].formatted == "[session] abcd1234")
    }

    @Test func toolStartShowsArgPreview() {
        var stream = EventStream()
        let lines = stream.ingest(#"{"type":"tool_execution_start","toolName":"search","args":{"query":"acme corp"}}"#)
        #expect(lines.count == 1)
        #expect(lines[0].scope == "tool")
        #expect(lines[0].message == "search: acme corp")
    }

    @Test func toolEndOnlyEmitsOnError() {
        var stream = EventStream()
        let ok = stream.ingest(#"{"type":"tool_execution_end","toolName":"search","isError":false}"#)
        #expect(ok.isEmpty)
        let bad = stream.ingest(#"{"type":"tool_execution_end","toolName":"read","isError":true,"result":"unknown alias r3"}"#)
        #expect(bad.count == 1)
        #expect(bad[0].scope == "tool!")
        #expect(bad[0].message == "read: unknown alias r3")
    }

    @Test func compactionEvents() {
        var stream = EventStream()
        let start = stream.ingest(#"{"type":"compaction_start"}"#)
        #expect(start.first?.formatted == "[compact] start")
        let end = stream.ingest(#"{"type":"compaction_end"}"#)
        #expect(end.first?.formatted == "[compact] end")
    }

    @Test func errorEventTruncatesLongMessages() {
        var stream = EventStream()
        let long = String(repeating: "x", count: 250)
        let lines = stream.ingest(#"{"type":"error","message":"\#(long)"}"#)
        #expect(lines.count == 1)
        #expect(lines[0].scope == "error")
        #expect(lines[0].message.count <= 200)
    }

    @Test func agentEndFlushesAccumulatedFinalText() {
        var stream = EventStream()
        _ = stream.ingest(#"{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"All done."}]}}"#)
        let lines = stream.ingest(#"{"type":"agent_end"}"#)
        #expect(lines.count == 3)
        #expect(lines[0].scope.isEmpty)
        #expect(lines[1].isFinalText)
        #expect(lines[1].message == "All done.")
        #expect(lines[2].scope == "done")
    }

    @Test func nonJsonLinePassesThroughAsRaw() {
        var stream = EventStream()
        let lines = stream.ingest("welp this is not json")
        #expect(lines.count == 1)
        #expect(lines[0].scope == "raw")
    }

    @Test func debugModePassesEverythingThrough() {
        var stream = EventStream(debug: true)
        let json = #"{"type":"agent_start","extra":"info"}"#
        let lines = stream.ingest(json)
        #expect(lines.count == 1)
        #expect(lines[0].formatted == json)
    }

    @Test func unknownEventTypesAreSilent() {
        var stream = EventStream()
        let lines = stream.ingest(#"{"type":"some_future_event","data":42}"#)
        #expect(lines.isEmpty)
    }
}
