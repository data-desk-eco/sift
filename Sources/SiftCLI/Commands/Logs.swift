import ArgumentParser
import Darwin
import Foundation
import SiftCore

struct LogsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "logs",
        abstract: "Tail the most recent auto-session log."
    )

    @Argument(help: "session name (defaults to the most recent one)")
    var session: String?

    @Flag(name: [.short, .customLong("follow")],
          help: "follow the log as it grows (Ctrl-C to stop)")
    var follow: Bool = false

    func run() async throws {
        do {
            let state: RunState
            if let name = session {
                guard let s = RunRegistry.read(name) else {
                    throw SiftError(
                        "no such session: \(name)",
                        suggestion: "run 'sift status -a' to list them"
                    )
                }
                state = s
            } else {
                guard let s = RunRegistry.mostRecent() else {
                    throw SiftError("no sift auto sessions on record")
                }
                state = s
            }

            let logURL = URL(filePath: state.logPath)
            if !FileManager.default.fileExists(atPath: logURL.path) {
                throw SiftError(
                    "log file missing: \(logURL.path)",
                    suggestion: "the session may have failed to start; check 'sift status -a'"
                )
            }

            if follow {
                try await tail(logURL: logURL, state: state)
            } else {
                let data = (try? Data(contentsOf: logURL)) ?? Data()
                FileHandle.standardOutput.write(data)
            }
        } catch {
            throw ExitCode(reportSiftError(error))
        }
    }

    private func tail(logURL: URL, state: RunState) async throws {
        let handle = try FileHandle(forReadingFrom: logURL)
        defer { try? handle.close() }
        // Print existing content first.
        if let chunk = try? handle.readToEnd() {
            FileHandle.standardOutput.write(chunk)
        }
        let sessionName = state.session
        while true {
            try? Task.checkCancellation()
            try await Task.sleep(nanoseconds: 250_000_000)
            if let chunk = try? handle.readToEnd(), !chunk.isEmpty {
                FileHandle.standardOutput.write(chunk)
            } else if let st = RunRegistry.read(sessionName), st.status != .running {
                // Process finished. Print one final newline if needed and exit.
                FileHandle.standardOutput.write(Data("[\(st.status.rawValue)]\n".utf8))
                return
            }
        }
    }
}
