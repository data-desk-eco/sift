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

    @Test func nextIsNilWhenEverythingDone() throws {
        let url = try tempList("✓ one\n# note\n\n")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(Worklist.next(at: url) == nil)
    }
}
