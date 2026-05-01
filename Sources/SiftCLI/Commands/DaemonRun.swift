import ArgumentParser
import Darwin
import Foundation
import SiftCore

/// Hidden subcommand: the actual headless agent loop. Re-exec'd by
/// `sift auto "PROMPT"` with POSIX_SPAWN_SETSID so it outlives the
/// parent shell. Not shown in --help.
struct DaemonRunCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "_daemon",
        abstract: "internal: detached agent runner",
        shouldDisplay: false
    )

    @Option(name: .customLong("session-dir")) var sessionDir: String
    @Option(name: .customLong("prompt")) var prompt: String
    @Flag(name: .customLong("resuming")) var resuming: Bool = false
    @Flag(name: .customLong("debug")) var debug: Bool = false
    @Option(name: .customLong("deadline-start")) var deadlineStart: Int?
    @Option(name: .customLong("deadline-end")) var deadlineEnd: Int?

    func run() async throws {
        SystemPrompt.resourceFinder = { siftCLIResources() }

        let deadline: Deadline?
        if let s = deadlineStart, let e = deadlineEnd {
            deadline = Deadline(startTimestamp: s, endTimestamp: e)
        } else {
            deadline = nil
        }

        do {
            let dir = URL(filePath: sessionDir)
            let prelaunch = try await PiRunner.prepare(
                sessionDir: dir, resuming: resuming,
                deadline: deadline, skillDir: skillDir()
            )
            FileManager.default.changeCurrentDirectoryPath(prelaunch.sessionDir.path)
            let code = try await PiRunner.runDaemon(
                prelaunch: prelaunch, prompt: prompt, debug: debug
            )
            throw ExitCode(code)
        } catch let exit as ExitCode {
            throw exit
        } catch {
            // Best-effort: record failure in run state if we got that far.
            let session = URL(filePath: sessionDir).lastPathComponent
            try? RunRegistry.update(session) { st in
                st.status = .failed
                st.lastScope = "error"
                st.lastMessage = error.localizedDescription
                st.finishedAt = Int(Date().timeIntervalSince1970)
            }
            throw ExitCode(reportSiftError(error))
        }
    }
}
