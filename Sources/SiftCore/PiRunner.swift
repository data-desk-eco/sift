import Darwin
import Foundation

/// Orchestrates a `sift auto` run. Two modes:
///
/// 1. **Foreground REPL** — `sift auto` with no prompt. Replaces the
///    current process with pi via execve so the user gets pi's TUI.
///    No daemon, no run-state file.
///
/// 2. **Headless detached** — `sift auto "prompt"`. The CLI re-execs
///    itself in a hidden `_daemon` subcommand which calls setsid(),
///    spawns pi, filters its JSON event stream into a per-session log,
///    and updates the run-state JSON the menu bar app watches. Posts a
///    finish-notification when pi exits.
public enum PiRunner {

    public struct Prelaunch: Sendable {
        public var session: String
        public var sessionDir: URL
        public var resuming: Bool
        public var hasPriorPiHistory: Bool
        public var env: [String: String]
        public var systemPromptPath: URL
        public var skillDir: URL
        public var piSessionDir: URL
    }

    /// Decide what session to resume / create. Synchronous for the easy
    /// cases. The caller (CLI auto command) is responsible for calling
    /// `AISlug.make()` when it needs a fresh slugged session.
    public struct SessionResolution: Sendable {
        public var sessionDir: URL
        public var resuming: Bool
        public var staleAge: String?  // "13h" / "3d" if resuming an old session
        public init(sessionDir: URL, resuming: Bool, staleAge: String? = nil) {
            self.sessionDir = sessionDir
            self.resuming = resuming
            self.staleAge = staleAge
        }
    }

    public static let staleSessionHours = 24

    public static func resolveSession(
        researchDir: URL, prompt: String?, newSession: Bool, freshSlug: String?
    ) -> SessionResolution {
        if !newSession, let last = mostRecentSession(researchDir: researchDir) {
            let lastMod = lastModified(of: last)
            let ageHours = (Date().timeIntervalSince1970 - lastMod) / 3600
            let stale = ageHours >= Double(staleSessionHours) ? formatAge(ageHours) : nil
            return SessionResolution(sessionDir: last, resuming: true, staleAge: stale)
        }
        if let prompt, !prompt.isEmpty {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            formatter.locale = Locale(identifier: "en_US_POSIX")
            let ts = formatter.string(from: Date())
            let slug = (freshSlug?.isEmpty == false) ? freshSlug! : ts
            let name = freshSlug.map { _ in "\(ts)-\(slug)" } ?? ts
            return SessionResolution(
                sessionDir: researchDir.appending(path: name),
                resuming: false, staleAge: nil
            )
        }
        return SessionResolution(
            sessionDir: researchDir.appending(path: "default"),
            resuming: false, staleAge: nil
        )
    }

    /// Wire up everything pi needs: backend started, pi config written,
    /// system prompt assembled, env populated, session dir ensured.
    public static func prepare(
        sessionDir: URL, resuming: Bool,
        deadline: Deadline?, skillDir: URL
    ) async throws -> Prelaunch {
        try Sift.ensureInitialized()
        try requirePi()

        try Backend.start()
        try Backend.configurePi()

        let dlNote = deadline.map { dl in
            SystemPrompt.DeadlineNote(
                totalMinutes: max(1, (dl.endTimestamp - dl.startTimestamp) / 60),
                endLocalTime: localTimeShort(dl.endTimestamp)
            )
        }
        let promptPath = try SystemPrompt.build(deadlineNote: dlNote)

        let vault = VaultService()
        let mp = try (vault.findExistingMount() ?? vault.unlock())
        let researchDir = mp.appending(path: "research")
        try Paths.ensure(researchDir)
        try Paths.ensure(sessionDir)

        let piSessionDir = sessionDir.appending(path: ".pi-sessions")
        let hasHistory: Bool
        if FileManager.default.fileExists(atPath: piSessionDir.path) {
            hasHistory = !((try? FileManager.default.contentsOfDirectory(atPath: piSessionDir.path)) ?? []).isEmpty
        } else {
            hasHistory = false
        }
        try Paths.ensure(piSessionDir)

        var env = ProcessInfo.processInfo.environment
        env["PI_CODING_AGENT_DIR"] = Paths.piConfigDir.path
        env["VAULT_MOUNT"] = mp.path
        env["ALEPH_SESSION_DIR"] = researchDir.path
        env["ALEPH_SESSION"] = sessionDir.lastPathComponent
        env["ALEPH_DB_PATH"] = sessionDir.appending(path: "aleph.sqlite").path
        env["SIFT_FINDINGS_DB"] = sessionDir.appending(path: "findings.db").path
        if let url = Keychain.get(Keychain.Key.alephURL)    { env["ALEPH_URL"]     = url }
        if let key = Keychain.get(Keychain.Key.alephAPIKey) { env["ALEPH_API_KEY"] = key }
        if let dl = deadline {
            env["SIFT_DEADLINE_TS"] = String(dl.endTimestamp)
            env["SIFT_DEADLINE_START_TS"] = String(dl.startTimestamp)
        }

        return Prelaunch(
            session: sessionDir.lastPathComponent,
            sessionDir: sessionDir,
            resuming: resuming,
            hasPriorPiHistory: hasHistory,
            env: env,
            systemPromptPath: promptPath,
            skillDir: skillDir,
            piSessionDir: piSessionDir
        )
    }

    // MARK: - Foreground REPL

    public static func execReplaceWithPi(prelaunch: Prelaunch) -> Never {
        var args = [
            "pi",
            "--system-prompt", prelaunch.systemPromptPath.path,
            "--skill", prelaunch.skillDir.path,
            "--session-dir", prelaunch.piSessionDir.path,
        ]
        if prelaunch.resuming, prelaunch.hasPriorPiHistory {
            args.append("--continue")
        }
        execvpeOrDie("pi", args, env: prelaunch.env)
    }

    // MARK: - Daemon mode

    public static func runDaemon(
        prelaunch: Prelaunch, prompt: String, debug: Bool
    ) async throws -> Int32 {
        let logPath = prelaunch.sessionDir.appending(path: "auto.log")
        if !FileManager.default.fileExists(atPath: logPath.path) {
            FileManager.default.createFile(atPath: logPath.path, contents: nil)
        }
        guard let logHandle = try? FileHandle(forWritingTo: logPath) else {
            throw SiftError("can't open \(logPath.path) for write")
        }
        try logHandle.seekToEnd()

        var state = RunState(
            session: prelaunch.session,
            sessionDir: prelaunch.sessionDir.path,
            logPath: logPath.path,
            prompt: prompt,
            pid: getpid(),
            startedAt: Int(Date().timeIntervalSince1970)
        )
        if let dlEnd = prelaunch.env["SIFT_DEADLINE_TS"],
           let dlStart = prelaunch.env["SIFT_DEADLINE_START_TS"] {
            state.deadlineTs = Int(dlEnd)
            state.deadlineStartTs = Int(dlStart)
        }
        try RunRegistry.write(state)

        var args = [
            "--system-prompt", prelaunch.systemPromptPath.path,
            "--skill", prelaunch.skillDir.path,
            "--session-dir", prelaunch.piSessionDir.path,
        ]
        if prelaunch.resuming, prelaunch.hasPriorPiHistory {
            args.append("--continue")
        }
        args.append(contentsOf: ["-p", "--mode", "json", prompt])

        let pi = Process()
        pi.executableURL = URL(filePath: try resolveExecutable("pi"))
        pi.arguments = args
        pi.environment = prelaunch.env
        pi.currentDirectoryURL = prelaunch.sessionDir

        let stdoutPipe = Pipe()
        let stderrPath = prelaunch.sessionDir.appending(path: "pi.stderr.log")
        if !FileManager.default.fileExists(atPath: stderrPath.path) {
            FileManager.default.createFile(atPath: stderrPath.path, contents: nil)
        }
        let stderrHandle = try FileHandle(forWritingTo: stderrPath)
        try stderrHandle.seekToEnd()

        pi.standardInput = FileHandle(forReadingAtPath: "/dev/null")
        pi.standardOutput = stdoutPipe
        pi.standardError = stderrHandle

        try pi.run()

        // Stream pi's stdout through the filter into the log + run state.
        var stream = EventStream(debug: debug)
        let reader = stdoutPipe.fileHandleForReading
        var buffer = Data()
        while true {
            let chunk = reader.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let nlIndex = buffer.firstIndex(of: 0x0a) {
                let lineData = buffer.subdata(in: 0..<nlIndex)
                buffer.removeSubrange(0...nlIndex)
                guard let line = String(data: lineData, encoding: .utf8) else { continue }
                for event in stream.ingest(line) {
                    if !event.formatted.isEmpty {
                        if let bytes = (event.formatted + "\n").data(using: .utf8) {
                            try? logHandle.write(contentsOf: bytes)
                        }
                    }
                    if !event.scope.isEmpty, !event.isFinalText {
                        try? RunRegistry.update(prelaunch.session) { st in
                            st.lastScope = event.scope
                            st.lastMessage = event.message
                            st.lastEventAt = Int(Date().timeIntervalSince1970)
                        }
                    }
                }
            }
        }

        pi.waitUntilExit()
        try? logHandle.close()
        try? stderrHandle.close()

        let code = pi.terminationStatus
        let now = Int(Date().timeIntervalSince1970)
        try RunRegistry.update(prelaunch.session) { st in
            st.status = code == 0 ? .finished : .failed
            st.exitCode = code
            st.finishedAt = now
            st.lastEventAt = now
        }
        notifyFinished(session: prelaunch.session, success: code == 0)
        return code
    }

    // MARK: - Helpers

    public static func mostRecentSession(researchDir: URL) -> URL? {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: researchDir, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey]
        ) else { return nil }
        let dirs = entries.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                && $0.lastPathComponent != "default"
        }
        return dirs.max { lastModified(of: $0) < lastModified(of: $1) }
    }

    public static func lastModified(of url: URL) -> TimeInterval {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return ((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970) ?? 0
    }

    public static func formatAge(_ hours: Double) -> String {
        if hours < 48 { return "\(Int(hours))h" }
        return "\(Int(hours / 24))d"
    }

    public static func newSessionName(prompt: String) async -> String {
        let slug = await AISlug.make(prompt: prompt)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let ts = formatter.string(from: Date())
        return slug.isEmpty ? ts : "\(ts)-\(slug)"
    }

    /// pi is installed by sift's installer into Application Support; the
    /// CLI also looks on $PATH as a fallback for ad-hoc dev installs.
    private static func requirePi() throws {
        if Paths.findExecutable("pi") != nil { return }
        throw SiftError(
            "the pi agent harness isn't installed",
            suggestion: "re-run the sift installer, or `make install-pi` from a source checkout"
        )
    }

    private static func resolveExecutable(_ name: String) throws -> String {
        guard let path = Paths.findExecutable(name) else {
            throw SiftError(
                "missing dependency: \(name)",
                suggestion: name == "pi"
                    ? "re-run the sift installer to reinstall it"
                    : "install \(name) and try again"
            )
        }
        return path
    }

    private static func localTimeShort(_ ts: Int) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }

    private static func notifyFinished(session: String, success: Bool) {
        let title = success ? "sift: investigation complete" : "sift: investigation failed"
        let body = "Session \(session) — open report.md or run `sift logs`"
        let safeTitle = title.replacingOccurrences(of: "\"", with: "\\\"")
        let safeBody = body.replacingOccurrences(of: "\"", with: "\\\"")
        let script = "display notification \"\(safeBody)\" with title \"\(safeTitle)\""
        _ = try? Subprocess.run(["/usr/bin/osascript", "-e", script])
    }
}

// MARK: - execvpe wrapper

func execvpeOrDie(_ program: String, _ args: [String], env: [String: String]) -> Never {
    let argvPtrs: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]
    let envvStrings = env.map { "\($0.key)=\($0.value)" }
    let envvPtrs: [UnsafeMutablePointer<CChar>?] = envvStrings.map { strdup($0) } + [nil]

    argvPtrs.withUnsafeBufferPointer { argv in
        envvPtrs.withUnsafeBufferPointer { envp in
            if let path = Subprocess.which(program) {
                _ = path.withCString { cpath in
                    Darwin.execve(
                        cpath,
                        UnsafeMutablePointer(mutating: argv.baseAddress),
                        UnsafeMutablePointer(mutating: envp.baseAddress)
                    )
                }
            }
        }
    }
    perror("execve")
    exit(127)
}
