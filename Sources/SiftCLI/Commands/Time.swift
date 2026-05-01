import ArgumentParser
import Foundation
import SiftCore

struct TimeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "time",
        abstract: "Show remaining time and pacing for the current session."
    )

    func run() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let endStr = env["SIFT_DEADLINE_TS"],
              let startStr = env["SIFT_DEADLINE_START_TS"],
              let end = Int(endStr),
              let start = Int(startStr)
        else {
            print("no deadline set for this session — pace yourself normally")
            return
        }
        let deadline = Deadline(startTimestamp: start, endTimestamp: end)
        let phase = deadline.phase
        let remaining = Deadline.formatRemaining(deadline.remainingSeconds)
        print("remaining: \(remaining)  (\(phase.name))")
        print(phase.guidance)
    }
}
