import Foundation
import Testing
@testable import SiftCore

@Suite struct WorklistTests {

    private func tempList(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "worklist-\(UUID().uuidString).txt")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func skipsBlanksCommentsAndDoneLines() throws {
        let url = try tempList("# header\n\n✓ already done\nsanctions on oil exports\nbank rossiya\n")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(Worklist.next(at: url) == "sanctions on oil exports")
    }

    @Test func markDoneAdvancesToNext() throws {
        let url = try tempList("first topic\nsecond topic\n")
        defer { try? FileManager.default.removeItem(at: url) }
        Worklist.markDone(at: url, topic: "first topic")
        #expect(Worklist.next(at: url) == "second topic")
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("✓ first topic"))
    }

    @Test func appendQueuesNewTopicAndDedupes() throws {
        let url = try tempList("alpha\n")
        defer { try? FileManager.default.removeItem(at: url) }
        try Worklist.append(at: url, topic: "beta")
        try Worklist.append(at: url, topic: "beta")  // duplicate — no-op
        try Worklist.append(at: url, topic: "alpha")  // already pending — no-op
        let lines = try String(contentsOf: url, encoding: .utf8)
            .components(separatedBy: "\n").filter { !$0.isEmpty }
        #expect(lines == ["alpha", "beta"])
    }

    @Test func rebuildFromLedgerRecoversClobberedLeads() throws {
        // Mimic a run dir: queue several leads, then have a "stray write"
        // clobber the visible worklist down to one line.
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "wl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "topics.txt")
        for lead in ["one", "two", "three"] { try Worklist.append(at: url, topic: lead) }
        try "three\n".write(to: url, atomically: true, encoding: .utf8)  // clobber

        Worklist.rebuildFromLedger(at: url)
        let leads = try String(contentsOf: url, encoding: .utf8)
            .components(separatedBy: "\n").filter { Worklist.isPending($0) }
        #expect(leads == ["one", "two", "three"])
    }

    @Test func nextIsNilWhenEverythingDone() throws {
        let url = try tempList("✓ one\n# note\n\n")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(Worklist.next(at: url) == nil)
    }
}
