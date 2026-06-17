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
        abstract: "Add a topic to this run's worklist for a later session."
    )

    @Argument(help: "the lead to investigate later")
    var topic: [String]

    func execute() async throws {
        let text = topic.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw SiftError("nothing to queue", suggestion: "sift queue \"a lead worth chasing\"")
        }
        guard let path = ProcessInfo.processInfo.environment["SIFT_TOPIC_LIST"],
              !path.isEmpty else {
            throw SiftError(
                "no active worklist",
                suggestion: "`sift queue` only works inside a `sift auto` run"
            )
        }
        try Worklist.append(at: URL(filePath: path), topic: text)
        Log.say("queue", "added: \(text)")
    }
}
