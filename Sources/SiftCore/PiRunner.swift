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
        researchDir: URL, prompt: String?, newSession: Bool,
        leadDir: URL? = nil, freshSlug: String? = nil
    ) -> SessionResolution {
        // Active lead — if the user has pinned one — wins over "most
        // recent" so a typed `sift auto` always lands on the same
        // investigation until they explicitly --new or `sift lead --clear`.
        if !newSession, let leadDir {
            return SessionResolution(sessionDir: leadDir, resuming: true, staleAge: nil)
        }
        if !newSession, let last = mostRecentSession(researchDir: researchDir) {
            let lastMod = lastModified(of: last)
            let ageHours = (Date().timeIntervalSince1970 - lastMod) / 3600
            let stale = ageHours >= Double(staleSessionHours) ? formatAge(ageHours) : nil
            return SessionResolution(sessionDir: last, resuming: true, staleAge: stale)
        }
        if let prompt, !prompt.isEmpty {
            let base = (freshSlug?.isEmpty == false) ? freshSlug! : fallbackTimestamp()
            let name = uniqueName(researchDir: researchDir, base: base)
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
        // Run pi in offline mode: no version-check banner, no package-update
        // banner, no startup network calls. Sift bundles its own pi and
        // controls its lifecycle; users don't manage updates themselves.
        env["PI_OFFLINE"] = "1"
        env["VAULT_MOUNT"] = mp.path
        env["ALEPH_SESSION_DIR"] = researchDir.path
        env["ALEPH_SESSION"] = sessionDir.lastPathComponent
        // ALEPH_DB_PATH is intentionally NOT set: Session.dbPath() then
        // resolves it to <vault>/research/aleph.sqlite, which is shared
        // across every session on this vault. That's what makes alias
        // refs stable across investigations (`r5` resolves to the same
        // entity in every session) and avoids re-paying the API cost
        // for entities a previous session already cached.
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
        let logHandle: FileHandle
        do {
            logHandle = try RotatingLog.openForAppend(at: logPath)
        } catch {
            throw SiftError("can't open \(logPath.path) for write")
        }

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
        let stderrHandle = try RotatingLog.openForAppend(at: stderrPath)

        pi.standardInput = FileHandle(forReadingAtPath: "/dev/null")
        pi.standardOutput = stdoutPipe
        pi.standardError = stderrHandle

        try pi.run()

        // Stream pi's stdout through the filter into the log + run state.
        var stream = EventStream(debug: debug)
        let reader = stdoutPipe.fileHandleForReading
        var buffer = Data()
        // Cap any single line so a runaway event payload can't OOM the
        // daemon. Pi's JSON events are kilobytes in practice; 4 MiB
        // covers tool-result blobs comfortably and discards the rest.
        let maxLineBytes = 4 * 1024 * 1024
        var dropping = false
        while true {
            let chunk = reader.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let nlIndex = buffer.firstIndex(of: 0x0a) {
                let lineData = buffer.subdata(in: 0..<nlIndex)
                buffer.removeSubrange(0...nlIndex)
                if dropping {
                    // We just consumed the trailing newline of an oversized
                    // line; pick up the next one fresh.
                    dropping = false
                    continue
                }
                guard let line = String(data: lineData, encoding: .utf8) else { continue }
                for event in stream.ingest(line) {
                    if !event.formatted.isEmpty {
                        if let bytes = (event.formatted + "\n").data(using: .utf8) {
                            try? logHandle.write(contentsOf: bytes)
                        }
                    }
                    if !event.scope.isEmpty, !event.isFinalText {
                        // Skip clobber-protect: if `sift stop` flipped the
                        // status to .stopped while we were reading the file,
                        // don't write .running back over it.
                        try? RunRegistry.updateIfRunning(prelaunch.session) { st in
                            st.lastScope = event.scope
                            st.lastMessage = event.message
                            st.lastEventAt = Int(Date().timeIntervalSince1970)
                        }
                    }
                }
            }
            // No newline yet but the buffer is past the cap — drop the
            // partial line and ignore everything until the next newline.
            if !dropping, buffer.count > maxLineBytes {
                buffer.removeAll(keepingCapacity: false)
                dropping = true
                try? logHandle.write(contentsOf: Data(
                    "[stream]   dropped oversized event line\n".utf8
                ))
            }
        }

        pi.waitUntilExit()
        try? logHandle.close()
        try? stderrHandle.close()

        let code = pi.terminationStatus
        let now = Int(Date().timeIntervalSince1970)
        try RunRegistry.update(prelaunch.session) { st in
            // If `sift stop` already flipped this to .stopped, keep that —
            // pi exits non-zero on SIGTERM and we don't want the user's
            // stop intent reported back as a failure.
            if st.status != .stopped {
                st.status = code == 0 ? .finished : .failed
            }
            st.exitCode = code
            st.finishedAt = now
            st.lastEventAt = now
        }
        // If this was the last running session, free the local llama
        // model from unified memory — otherwise it keeps ~14 GB pinned
        // and the rest of the Mac runs slowly.
        Backend.stopLocalIfIdle()
        // The menu bar app posts a native UNUserNotification when it
        // sees the run-state file flip out of `.running`.
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

    /// Bring up the bundled menu bar app so a freshly spawned daemon
    /// gets a live status indicator without the user having to click
    /// anything. `open -gb` is idempotent — a no-op if the app is
    /// already running, and silently fails if Sift.app isn't installed
    /// (the daemon still works fine; the user just won't see the
    /// indicator until they `open Sift.app` themselves).
    public static func ensureMenuBarRunning() {
        _ = try? Subprocess.run(
            ["/usr/bin/open", "-gb", "eco.datadesk.sift.menubar"]
        )
    }

    /// Build a session name from the LLM-generated slug. Falls back to a
    /// timestamp only when slug generation fails (and the caller will
    /// pass it through `uniqueName` to avoid colliding with an existing
    /// directory).
    public static func newSessionName(prompt: String, researchDir: URL) async -> String {
        let slug = await AISlug.make(prompt: prompt)
        let base = slug.isEmpty ? fallbackTimestamp() : slug
        return uniqueName(researchDir: researchDir, base: base)
    }

    static func fallbackTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: Date())
    }

    /// Append `-2`, `-3`, … if `<researchDir>/<base>` is already taken.
    /// Slugs aren't guaranteed unique across investigations of the same
    /// subject; collisions are rare but real.
    static func uniqueName(researchDir: URL, base: String) -> String {
        let fm = FileManager.default
        if !fm.fileExists(atPath: researchDir.appending(path: base).path) {
            return base
        }
        var n = 2
        while fm.fileExists(atPath: researchDir.appending(path: "\(base)-\(n)").path) {
            n += 1
        }
        return "\(base)-\(n)"
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
