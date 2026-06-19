import ArgumentParser
import Foundation
import SiftCore

/// Add a topic to the current run's worklist so a later session picks it
/// up. Agent-facing — the agent calls this when it surfaces a fresh lead
/// worth investigating beyond its current topic. Only meaningful inside
/// a `sift auto` run, which sets `$SIFT_TOPIC_LIST` to the worklist path.
struct QueueCommand: SiftSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "queue",
        abstract: "Add a topic to this run's worklist for a later session.",
        shouldDisplay: false
    )

    @Argument(help: "the lead to investigate later")
    var topic: [String] = []
    @Flag(name: .customLong("list"), help: "show the current worklist instead of adding")
    var list: Bool = false

    func execute() async throws {
        guard let path = ProcessInfo.processInfo.environment["SIFT_TOPIC_LIST"],
              !path.isEmpty else {
            throw SiftError(
                "no active worklist",
                suggestion: "`sift queue` only works inside a `sift auto` run"
            )
        }
        let url = URL(filePath: path)
        let text = topic.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)

        // No lead (or `--list`): print the worklist so the agent can
        // confirm what's queued instead of re-adding to check.
        if list || text.isEmpty {
            let pending = Worklist.pending(at: url)
            guard !pending.isEmpty else { return Log.say("queue", "worklist empty") }
            Log.say("queue", "\(pending.count) queued:")
            for (i, t) in pending.enumerated() { Log.say("queue", "  \(i + 1). \(t)") }
            return
        }

        let before = Worklist.pending(at: url)
        try Worklist.append(at: url, topic: text)
        let now = Worklist.pending(at: url).count
        Log.say("queue", before.contains(text) ? "already queued (\(now) total)" : "added (\(now) total): \(text)")
    }
}
