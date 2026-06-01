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
    @Option(name: .customLong("marathon-end")) var marathonEnd: Int?

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
            // For marathon runs the leg loop owns prepare() — it needs
            // to rebuild the system prompt and pi session dir per leg.
            // Outside marathon we keep the original one-shot flow.
            FileManager.default.changeCurrentDirectoryPath(dir.path)
            // Write a `.running` sidecar BEFORE prepare(). prepare() blocks
            // on a cold llama-server boot (seconds to minutes) and throws if
            // it fails; without an early sidecar that whole window — and any
            // boot failure — is invisible to `sift status`/`sift lead`/the
            // menu bar, and the catch handler's `update` (which only mutates
            // an existing sidecar) has nothing to mark failed. runMarathon
            // and runDaemon both overwrite this with their fuller state.
            var initial = RunState(
                session: dir.lastPathComponent,
                sessionDir: dir.path,
                logPath: dir.appending(path: "auto.log").path,
                prompt: prompt,
                pid: getpid(),
                startedAt: Int(Date().timeIntervalSince1970),
                deadlineTs: deadline?.endTimestamp,
                deadlineStartTs: deadline?.startTimestamp
            )
            initial.marathonEndTs = marathonEnd
            try? RunRegistry.write(initial)
            let code: Int32
            if let endTs = marathonEnd {
                code = try await PiRunner.runMarathon(
                    sessionDir: dir, resuming: resuming,
                    legSeconds: deadline?.totalSeconds ?? (30 * 60),
                    marathonEndTs: endTs,
                    initialPrompt: prompt, debug: debug,
                    skillDirURL: skillDir()
                )
            } else {
                let prelaunch = try await PiRunner.prepare(
                    sessionDir: dir, resuming: resuming,
                    deadline: deadline, skillDir: skillDir()
                )
                FileManager.default.changeCurrentDirectoryPath(prelaunch.sessionDir.path)
                code = try await PiRunner.runDaemon(
                    prelaunch: prelaunch, prompt: prompt, debug: debug
                )
            }
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
