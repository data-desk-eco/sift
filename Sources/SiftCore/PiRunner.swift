import Darwin
import Foundation

/// Drives pi for `sift auto`. One pi process per topic, run in the
/// foreground to completion: `prepare()` wires up the environment +
/// system prompt + backend, `drivePi()` spawns pi headlessly and
/// streams its rendered event log to stderr so the operator watches
/// progress live. No daemon, no run-state sidecar — the worklist file
/// and the per-lead segment notes are the only state.
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

    /// Wire up everything pi needs: backend started, pi config written,
    /// system prompt assembled, env populated, session dir ensured.
    ///
    /// `legSubdir` gives each topic its own pi conversation: pi's session
    /// dir becomes `<sessionDir>/.pi-sessions/<legSubdir>` so every topic
    /// starts with a fresh context (no `--continue`), while report.md /
    /// segments/ / aleph.sqlite all stay shared across the run.
    public static func prepare(
        sessionDir: URL, resuming: Bool,
        deadline: Deadline?, skillDir: URL,
        legSubdir: String? = nil,
        deadlineKind: SystemPrompt.DeadlineNote.Kind = .investigate
    ) async throws -> Prelaunch {
        try Sift.ensureInitialized()
        try requirePi()

        try LlamaServer.start()
        try Backend.configurePi()

        let dlNote = deadline.map { dl in
            SystemPrompt.DeadlineNote(
                totalMinutes: max(1, (dl.endTimestamp - dl.startTimestamp) / 60),
                endLocalTime: localTimeShort(dl.endTimestamp),
                kind: deadlineKind
            )
        }
        let promptPath = try SystemPrompt.build(deadlineNote: dlNote)

        let vault = VaultService()
        // Caller (sift auto) unlocks the vault before we get here.
        let mp = try vault.requireMounted()
        let researchDir = mp.appending(path: "research")
        try Paths.ensure(researchDir)
        try Paths.ensure(sessionDir)

        let piSessionDir: URL
        if let sub = legSubdir, !sub.isEmpty {
            piSessionDir = sessionDir.appending(path: ".pi-sessions").appending(path: sub)
        } else {
            piSessionDir = sessionDir.appending(path: ".pi-sessions")
        }
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
        // refs stable across topics (`r5` resolves to the same entity in
        // every session on the vault) and avoids re-paying the API cost
        // for entities a previous topic already cached.
        let secrets = (try? SecretsStore.load(vault: vault)) ?? VaultSecrets()
        if let url = secrets.alephURL, !url.isEmpty { env["ALEPH_URL"] = url }
        if let key = secrets.alephAPIKey, !key.isEmpty { env["ALEPH_API_KEY"] = key }
        // Strip the passphrase env var before spawning pi — it should
        // never propagate beyond the CLI process that read it.
        env.removeValue(forKey: "SIFT_VAULT_PASSPHRASE")
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

    private static func piBaseArgs(prelaunch: Prelaunch) -> [String] {
        var args = [
            "--system-prompt", prelaunch.systemPromptPath.path,
            "--skill", prelaunch.skillDir.path,
            "--session-dir", prelaunch.piSessionDir.path,
        ]
        if prelaunch.resuming, prelaunch.hasPriorPiHistory {
            args.append("--continue")
        }
        return args
    }

    /// Run a single pi process to completion for one topic. pi runs
    /// headlessly (`-p --mode json`); we parse its JSON event stream and
    /// echo rendered lines to stderr so the operator sees searches and
    /// write-ups land in real time. Returns pi's termination status.
    ///
    /// A topic ends on whichever hard stop comes first: `deadline` (a
    /// wall-clock SIGTERM) or `maxSteps` (a tool-call SIGTERM). pi has no
    /// step/token cap of its own, and the soft deadline that `sift time`
    /// reports has no teeth in `--print` mode — left to self-pace the agent
    /// stops early (often without writing) or, on this hardware, just gets
    /// slower as its context grows. So `deadline` is the real governor: it
    /// holds a topic to its full time budget instead of an arbitrary call
    /// count that lands minutes short. `maxSteps` is now only a runaway
    /// backstop. The agent writes its segment as it goes, so ending mid-step
    /// loses only the in-flight call, not work already written down.
    public static func drivePi(
        prelaunch: Prelaunch, prompt: String, debug: Bool,
        maxSteps: Int? = nil, deadline: Deadline? = nil,
        onTool: ((String) -> Void)? = nil
    ) throws -> (code: Int32, finalText: String) {
        // `--no-session`: every sweep phase is a fresh, never-resumed
        // context, so persisting pi's conversation (and the compaction it
        // runs on save) is wasted work — minutes per topic on this
        // hardware. Ephemeral sessions skip both.
        let args = piBaseArgs(prelaunch: prelaunch) + ["--no-session", "-p", "--mode", "json", prompt]
        let stamp = makeStamp()

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

        var stream = EventStream(debug: debug)
        let out = FileHandle.standardError
        let reader = stdoutPipe.fileHandleForReading
        var buffer = Data()
        // Cap any single line so a runaway event payload can't OOM us.
        let maxLineBytes = 4 * 1024 * 1024
        var dropping = false
        var steps = 0, capped = false
        readLoop: while true {
            let chunk = reader.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let nlIndex = buffer.firstIndex(of: 0x0a) {
                let lineData = buffer.subdata(in: 0..<nlIndex)
                buffer.removeSubrange(0...nlIndex)
                if dropping { dropping = false; continue }
                guard let line = String(data: lineData, encoding: .utf8) else { continue }
                for event in stream.ingest(line) {
                    if event.scope == "tool" { steps += 1; onTool?(event.message) }
                    guard !event.formatted.isEmpty else { continue }
                    let rendered = event.isFinalText
                        ? event.formatted + "\n"
                        : "\(stamp()) \(event.formatted)\n"
                    if let bytes = rendered.data(using: .utf8) {
                        try? out.write(contentsOf: bytes)
                    }
                }
                if let cap = maxSteps, steps >= cap {
                    capped = true
                    try? out.write(contentsOf: Data(
                        "\(stamp()) [limit]   \(cap) tool calls — ending this session\n".utf8
                    ))
                    pi.terminate()
                    break readLoop
                }
                // Wall-clock stop: hold the topic to its full time budget.
                // Checked as events stream (between tool calls), so it fires
                // within a call of the deadline, not to the millisecond.
                if let dl = deadline, dl.remainingSeconds <= 0 {
                    capped = true
                    try? out.write(contentsOf: Data(
                        "\(stamp()) [deadline] time budget reached — ending this session\n".utf8
                    ))
                    pi.terminate()
                    break readLoop
                }
            }
            if !dropping, buffer.count > maxLineBytes {
                buffer.removeAll(keepingCapacity: false)
                dropping = true
                try? out.write(contentsOf: Data(
                    "\(stamp()) [stream]   dropped oversized event line\n".utf8
                ))
            }
        }

        pi.waitUntilExit()
        try? stderrHandle.close()
        // A capped session is a clean stop on our terms, not a failure.
        // finalText is the agent's closing message — the orchestrator
        // falls back to it when the agent investigated but never wrote
        // its deliverable file itself.
        return (capped ? 0 : pi.terminationStatus, stream.finalText)
    }

    // MARK: - Helpers

    // UTC wall-clock prefix for every structured event line so the
    // operator can correlate searches and findings. Final-text dumps
    // (the agent's prose) are written without a prefix so they read as
    // natural paragraphs.
    private static func makeStamp() -> () -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss'Z'"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        return { formatter.string(from: Date()) }
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
