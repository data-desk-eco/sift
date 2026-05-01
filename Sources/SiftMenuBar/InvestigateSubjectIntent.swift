import AppIntents
import Foundation
import SiftCore

/// Launch a `sift auto` investigation as a detached background daemon.
/// Surfaces the new session's name back to the caller (Shortcuts, Siri,
/// Raycast).
///
/// The intent shells out to the `sift` CLI rather than re-implementing
/// the daemon flow inline — that way we don't double-maintain the
/// session-resolve / vault-unlock / pi-spawn logic, and the host app
/// doesn't need any of the headless dependencies (pi, llama-server)
/// at app-launch time.
struct InvestigateSubjectIntent: AppIntent {
    static let title: LocalizedStringResource = "Investigate Subject"
    static let description = IntentDescription(
        "Launch a sift agent investigation in the background. The CLI handles vault unlock, backend startup, and progress streaming; the menu bar item shows live status."
    )

    @Parameter(title: "Subject",
               description: "What to investigate (e.g. 'Acme Corp in the Pandora Papers')")
    var subject: String

    @Parameter(title: "Time limit",
               description: "Soft deadline like 30m, 1h, 1h30m. Optional.",
               default: "")
    var timeLimit: String

    @Parameter(title: "New session",
               description: "Force a fresh session instead of continuing the most recent one.",
               default: false)
    var newSession: Bool

    static var openAppWhenRun: Bool { false }

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let trimmedSubject = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSubject.isEmpty else {
            throw $subject.needsValueError("What should I investigate?")
        }

        let cli = try resolveSiftBinary()
        var args = ["auto"]
        if newSession { args.append("--new") }
        let trimmedDeadline = timeLimit.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedDeadline.isEmpty {
            args.append(contentsOf: ["-t", trimmedDeadline])
        }
        args.append(trimmedSubject)

        let proc = Process()
        proc.executableURL = URL(filePath: cli)
        proc.arguments = args
        let stderr = Pipe()
        proc.standardError = stderr
        proc.standardOutput = FileHandle(forWritingAtPath: "/dev/null")

        do {
            try proc.run()
        } catch {
            throw SiftError(
                "couldn't launch sift CLI at \(cli): \(error.localizedDescription)",
                suggestion: "make sure sift is on PATH (see install instructions)"
            )
        }
        proc.waitUntilExit()

        let stderrData = (try? stderr.fileHandleForReading.readToEnd()) ?? Data()
        let stderrText = String(data: stderrData, encoding: .utf8) ?? ""

        if proc.terminationStatus != 0 {
            let snippet = stderrText.split(separator: "\n").prefix(3).joined(separator: " — ")
            return .result(
                value: "",
                dialog: IntentDialog("Couldn't start investigation: \(snippet)")
            )
        }

        // The CLI prints "[auto]     started <session> (pid <pid>)" on stderr.
        let session = parseSessionName(stderrText) ?? "session"
        return .result(
            value: session,
            dialog: IntentDialog("Started \(session). Check the sift menu bar item for progress.")
        )
    }

    private func resolveSiftBinary() throws -> String {
        // Prefer the in-bundle CLI (brew-cask installs ship sift inside
        // Sift.app/Contents/Resources/bin), then fall back to PATH for
        // dev installs. GUI apps don't inherit shell PATH, so we
        // augment with the common Homebrew prefixes that the user's
        // shell would add.
        if let bundled = Paths.bundledCLIBin?.path,
           FileManager.default.isExecutableFile(atPath: bundled) {
            return bundled
        }
        let env = ProcessInfo.processInfo.environment
        let userPath = env["PATH"] ?? ""
        let path = [
            userPath,
            "/opt/homebrew/bin",
            "\(NSHomeDirectory())/.local/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
        ].filter { !$0.isEmpty }.joined(separator: ":")
        for dir in path.split(separator: ":") {
            let candidate = "\(dir)/sift"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        throw SiftError(
            "sift CLI not found",
            suggestion: "install with `brew install --cask data-desk-eco/sift/sift`"
        )
    }

    private func parseSessionName(_ stderr: String) -> String? {
        for line in stderr.split(separator: "\n") {
            // Match "[auto]     started <session> (pid <n>)"
            let s = String(line)
            if let r = s.range(of: #"started\s+(\S+)\s+\(pid"#, options: .regularExpression) {
                let segment = s[r]
                let parts = segment.split(separator: " ")
                if parts.count >= 2 { return String(parts[1]) }
            }
        }
        return nil
    }
}

/// AppShortcuts entry so the intent shows up in Spotlight without the
/// user needing to open Shortcuts.app first.
struct SiftAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: InvestigateSubjectIntent(),
            phrases: [
                "Investigate \(\.$subject) with \(.applicationName)",
                "Have \(.applicationName) investigate \(\.$subject)",
                "Start a sift investigation of \(\.$subject)",
            ],
            shortTitle: "Investigate Subject",
            systemImageName: "magnifyingglass.circle"
        )
    }
}
