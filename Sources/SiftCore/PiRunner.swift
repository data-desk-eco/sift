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

    /// Decide what session to resume. Only resumes — fresh-session
    /// naming is the CLI's job (it has to prompt for a slug
    /// interactively), and `Auto` constructs its own `SessionResolution`
    /// once a slug is in hand.
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
        researchDir: URL, newSession: Bool, leadDir: URL? = nil
    ) -> SessionResolution {
        // When asked to resume, the active lead — if the user has pinned one —
        // wins over "most recent" so `sift auto --resume` lands on the same
        // investigation the user has pinned via `sift lead`.
        if !newSession, let leadDir {
            return SessionResolution(sessionDir: leadDir, resuming: true, staleAge: nil)
        }
        if !newSession, let last = mostRecentSession(researchDir: researchDir) {
            let lastMod = lastModified(of: last)
            let ageHours = (Date().timeIntervalSince1970 - lastMod) / 3600
            let stale = ageHours >= Double(staleSessionHours) ? formatAge(ageHours) : nil
            return SessionResolution(sessionDir: last, resuming: true, staleAge: stale)
        }
        return SessionResolution(
            sessionDir: researchDir.appending(path: "default"),
            resuming: false, staleAge: nil
        )
    }

    /// Wire up everything pi needs: backend started, pi config written,
    /// system prompt assembled, env populated, session dir ensured.
    ///
    /// `legSubdir` is for marathon mode — when set, pi's session dir is
    /// `<sessionDir>/.pi-sessions/<legSubdir>` instead of the shared
    /// `.pi-sessions/`. Each leg gets a fresh conversation that way,
    /// while report.md / findings.db / aleph.sqlite all stay shared.
    public static func prepare(
        sessionDir: URL, resuming: Bool,
        deadline: Deadline?, skillDir: URL,
        legSubdir: String? = nil
    ) async throws -> Prelaunch {
        try Sift.ensureInitialized()
        try requirePi()

        try LlamaServer.start()
        try ForgeProxy.start()
        try Backend.configurePi()

        let dlNote = deadline.map { dl in
            SystemPrompt.DeadlineNote(
                totalMinutes: max(1, (dl.endTimestamp - dl.startTimestamp) / 60),
                endLocalTime: localTimeShort(dl.endTimestamp)
            )
        }
        let promptPath = try SystemPrompt.build(deadlineNote: dlNote)

        let vault = VaultService()
        // Caller (sift auto / sift _daemon) is responsible for unlocking
        // the vault before we get here. The daemon never has a TTY and
        // can't prompt; the parent CLI unlocks via passphrase prompt then
        // re-execs into the daemon, which inherits the system mount.
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
        // refs stable across investigations (`r5` resolves to the same
        // entity in every session) and avoids re-paying the API cost
        // for entities a previous session already cached.
        env["SIFT_FINDINGS_DB"] = sessionDir.appending(path: "findings.db").path
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

    /// Args common to both pi launch modes (REPL via execve, daemon via
    /// Process). The REPL form additionally needs "pi" as argv[0]; the
    /// daemon form appends `-p --mode json <prompt>`.
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

    // MARK: - Foreground REPL

    public static func execReplaceWithPi(prelaunch: Prelaunch) -> Never {
        let args = ["pi"] + piBaseArgs(prelaunch: prelaunch)
        execvpeOrDie("pi", args, env: prelaunch.env)
    }

    // MARK: - Daemon spawn (parent side)

    /// Re-exec the current binary as `sift _daemon ...` with setsid so
    /// the resulting process survives our exit, then return. The child
    /// inherits our environment and writes its own sidecar from
    /// `runDaemon`. Called by `sift auto` when it has a prompt to run
    /// headlessly.
    public static func spawnDaemon(
        sessionDir: URL, resuming: Bool,
        prompt: String, deadline: Deadline?,
        marathonEnd: Int? = nil, debug: Bool
    ) throws -> pid_t {
        let exe = ProcessInfo.processInfo.arguments[0]
        // Resolve to absolute path so the child can find itself even if
        // the current shell PATH changes.
        let exePath: String
        if exe.hasPrefix("/") {
            exePath = exe
        } else if let resolved = Subprocess.which("sift") {
            exePath = resolved
        } else {
            exePath = exe
        }

        var args: [String] = [
            "_daemon",
            "--session-dir", sessionDir.path,
            "--prompt", prompt,
        ]
        if resuming { args.append("--resuming") }
        if debug    { args.append("--debug") }
        if let dl = deadline {
            args.append(contentsOf: [
                "--deadline-start", String(dl.startTimestamp),
                "--deadline-end",   String(dl.endTimestamp),
            ])
        }
        if let me = marathonEnd {
            args.append(contentsOf: ["--marathon-end", String(me)])
        }

        // Use posix_spawnp with POSIX_SPAWN_SETSID so the child detaches
        // from our session — survives shell exit, ignores SIGHUP.
        var attr = posix_spawnattr_t(nil as OpaquePointer?)
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))

        var fileActions = posix_spawn_file_actions_t(nil as OpaquePointer?)
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        // Redirect stdin/stdout/stderr to /dev/null so the child has no
        // tie to our terminal.
        for fd in [0, 1, 2] as [Int32] {
            posix_spawn_file_actions_addopen(
                &fileActions, fd, "/dev/null", O_RDWR, 0
            )
        }

        var argv: [UnsafeMutablePointer<CChar>?] =
            [strdup(exePath)] + args.map { strdup($0) } + [nil]
        var envv: [UnsafeMutablePointer<CChar>?] =
            ProcessInfo.processInfo.environment
                .map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            for p in argv where p != nil { free(p) }
            for p in envv where p != nil { free(p) }
        }

        var pid: pid_t = 0
        let rc = argv.withUnsafeMutableBufferPointer { argvBuf in
            envv.withUnsafeMutableBufferPointer { envvBuf in
                exePath.withCString { cpath in
                    posix_spawnp(&pid, cpath, &fileActions, &attr,
                                 argvBuf.baseAddress, envvBuf.baseAddress)
                }
            }
        }
        if rc != 0 {
            throw SiftError(
                "couldn't spawn daemon: \(String(cString: strerror(rc)))"
            )
        }
        return pid
    }

    // MARK: - Daemon body (child side)

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
        let stamp = makeStamp()

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

        let code = try driveOnePi(
            prelaunch: prelaunch, prompt: prompt, debug: debug,
            logHandle: logHandle, stamp: stamp
        )

        await runWrapUpIfNeeded(
            sessionDir: prelaunch.sessionDir, session: prelaunch.session,
            originalExitCode: code, skillDir: prelaunch.skillDir,
            legSubdir: nil, debug: debug,
            logHandle: logHandle, stamp: stamp
        )
        try? logHandle.close()

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
        // and the rest of the Mac runs slowly. Tear down forge first so
        // it doesn't briefly fire health checks at a dead llama-server.
        ForgeProxy.stopIfIdle()
        LlamaServer.stopLocalIfIdle()
        // The menu bar app posts a native UNUserNotification when it
        // sees the run-state file flip out of `.running`.
        return code
    }

    /// Marathon mode: loop multiple fresh-context pi legs against the
    /// same session dir. Between legs the system prompt is rebuilt for
    /// the new leg's deadline, pi gets a leg-specific session subdir
    /// (no `--continue`), and the agent picks up via the durable state
    /// in `report.md` / `findings.db`. llama-server stays warm across
    /// legs because the RunRegistry sees this daemon as still
    /// `.running`.
    public static func runMarathon(
        sessionDir: URL, resuming: Bool,
        legSeconds: Int, marathonEndTs: Int,
        initialPrompt: String, debug: Bool,
        skillDirURL: URL
    ) async throws -> Int32 {
        let logPath = sessionDir.appending(path: "auto.log")
        let logHandle: FileHandle
        do {
            logHandle = try RotatingLog.openForAppend(at: logPath)
        } catch {
            throw SiftError("can't open \(logPath.path) for write")
        }
        let stamp = makeStamp()
        let session = sessionDir.lastPathComponent

        let marathonStart = Int(Date().timeIntervalSince1970)
        var state = RunState(
            session: session,
            sessionDir: sessionDir.path,
            logPath: logPath.path,
            prompt: initialPrompt,
            pid: getpid(),
            startedAt: marathonStart
        )
        state.marathonEndTs = marathonEndTs
        state.legNumber = 0  // bumped to 1 before leg 1 starts
        try RunRegistry.write(state)

        // Smallest leg we're willing to start — anything shorter is too
        // little time for the agent to do useful work and just burns
        // budget on warm-up.
        let minLegSeconds = 60
        // If a leg returns in under this many seconds we treat it as a
        // flameout and stop the marathon — pi probably hit a crash loop
        // and re-running with a fresh prompt won't help.
        let minHealthyLegSeconds = 60

        var legNumber = 0
        var lastExitCode: Int32 = 0
        var legSubdirCounter = 1
        // Track the most recently used pi session subdir so the post-loop
        // wrap-up can --continue from the same context the last leg ran in.
        var lastLegSubdir: String?
        while true {
            let now = Int(Date().timeIntervalSince1970)
            let budgetRemaining = marathonEndTs - now
            if budgetRemaining < minLegSeconds { break }
            let thisLegSeconds = min(legSeconds, budgetRemaining)

            legNumber += 1
            let deadline = Deadline(
                startTimestamp: now, endTimestamp: now + thisLegSeconds
            )
            // Leg 1 uses the shared `.pi-sessions` dir so `--resume` /
            // `--continue` still picks up prior pi history. Leg 2+ get
            // their own subdir so each restart is a clean context.
            let legSubdir: String?
            if legNumber == 1 {
                legSubdir = nil
            } else {
                legSubdir = "leg-\(legSubdirCounter)"
                legSubdirCounter += 1
            }
            lastLegSubdir = legSubdir
            let prelaunch = try await prepare(
                sessionDir: sessionDir,
                resuming: resuming && legNumber == 1,
                deadline: deadline, skillDir: skillDirURL,
                legSubdir: legSubdir
            )
            let legPrompt = legNumber == 1
                ? initialPrompt
                : continuationPrompt(original: initialPrompt, legNumber: legNumber)

            // Surface the leg boundary in the log so the user can see
            // where one leg ended and the next began.
            let header = "\n\(stamp()) [marathon] leg \(legNumber) starting — \(Deadline.formatRemaining(thisLegSeconds)) deadline, \(Deadline.formatRemaining(budgetRemaining)) marathon budget remaining\n"
            try? logHandle.write(contentsOf: Data(header.utf8))

            try RunRegistry.update(session) { st in
                st.legNumber = legNumber
                st.deadlineTs = deadline.endTimestamp
                st.deadlineStartTs = deadline.startTimestamp
                st.lastScope = "marathon"
                st.lastMessage = "leg \(legNumber) starting"
                st.lastEventAt = Int(Date().timeIntervalSince1970)
                // Re-arm status — between legs we may have briefly
                // looked done from the menu bar's perspective, but the
                // daemon is still alive.
                if st.status != .stopped { st.status = .running }
            }

            let legStart = Int(Date().timeIntervalSince1970)
            let code = try driveOnePi(
                prelaunch: prelaunch, prompt: legPrompt, debug: debug,
                logHandle: logHandle, stamp: stamp
            )
            lastExitCode = code
            let legElapsed = Int(Date().timeIntervalSince1970) - legStart

            // Stop the marathon if the user pulled the plug.
            if let cur = RunRegistry.read(session), cur.status == .stopped {
                try? logHandle.write(contentsOf: Data(
                    "\(stamp()) [marathon] stopped by user after leg \(legNumber)\n".utf8
                ))
                break
            }
            // Pi crashed or exited non-zero — re-running with a fresh
            // prompt is unlikely to help and would burn budget.
            if code != 0 {
                try? logHandle.write(contentsOf: Data(
                    "\(stamp()) [marathon] leg \(legNumber) exited \(code) — stopping marathon\n".utf8
                ))
                break
            }
            // Flameout protection: pi exited cleanly but suspiciously
            // fast. Almost always a startup failure that's invisible at
            // the exit-code level (e.g. missing tool, prompt rejection).
            if legElapsed < minHealthyLegSeconds {
                try? logHandle.write(contentsOf: Data(
                    "\(stamp()) [marathon] leg \(legNumber) finished in \(legElapsed)s — stopping (looks like a flameout)\n".utf8
                ))
                break
            }
        }

        await runWrapUpIfNeeded(
            sessionDir: sessionDir, session: session,
            originalExitCode: lastExitCode, skillDir: skillDirURL,
            legSubdir: lastLegSubdir, debug: debug,
            logHandle: logHandle, stamp: stamp
        )
        try? logHandle.close()
        let endNow = Int(Date().timeIntervalSince1970)
        try RunRegistry.update(session) { st in
            if st.status != .stopped {
                st.status = lastExitCode == 0 ? .finished : .failed
            }
            st.exitCode = lastExitCode
            st.finishedAt = endNow
            st.lastEventAt = endNow
        }
        ForgeProxy.stopIfIdle()
        LlamaServer.stopLocalIfIdle()
        return lastExitCode
    }

    // UTC wall-clock prefix for every structured event line so a user
    // tailing `auto.log` can see when each tool call / state change
    // landed (and correlate across machines / timezones). Final-text
    // dumps (the agent's multi-line prose) are written without a
    // prefix so they read as natural paragraphs.
    private static func makeStamp() -> () -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss'Z'"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        return { formatter.string(from: Date()) }
    }

    /// Run a single pi process to completion, streaming its event log
    /// into `logHandle` and updating the run-state sidecar per event.
    /// Returns pi's termination status. Used by both the one-shot
    /// `runDaemon` and the looping `runMarathon` paths.
    private static func driveOnePi(
        prelaunch: Prelaunch, prompt: String, debug: Bool,
        logHandle: FileHandle, stamp: @escaping () -> String
    ) throws -> Int32 {
        let args = piBaseArgs(prelaunch: prelaunch) + ["-p", "--mode", "json", prompt]

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
                    dropping = false
                    continue
                }
                guard let line = String(data: lineData, encoding: .utf8) else { continue }
                for event in stream.ingest(line) {
                    if !event.formatted.isEmpty {
                        let rendered = event.isFinalText
                            ? event.formatted + "\n"
                            : "\(stamp()) \(event.formatted)\n"
                        if let bytes = rendered.data(using: .utf8) {
                            try? logHandle.write(contentsOf: bytes)
                        }
                    }
                    if !event.scope.isEmpty, !event.isFinalText {
                        try? RunRegistry.updateIfRunning(prelaunch.session) { st in
                            st.lastScope = event.scope
                            st.lastMessage = event.message
                            st.lastEventAt = Int(Date().timeIntervalSince1970)
                        }
                    }
                }
            }
            if !dropping, buffer.count > maxLineBytes {
                buffer.removeAll(keepingCapacity: false)
                dropping = true
                try? logHandle.write(contentsOf: Data(
                    "\(stamp()) [stream]   dropped oversized event line\n".utf8
                ))
            }
        }

        pi.waitUntilExit()
        try? stderrHandle.close()
        return pi.terminationStatus
    }

    // MARK: - Report wrap-up

    /// Minimum size we treat as a real attempt at a report. Anything
    /// smaller (a `touch`ed file, a one-line stub, an empty header) is
    /// indistinguishable from "the agent never wrote one" and we'd
    /// rather re-prompt than ship it. Stays well below the size of a
    /// single legitimate paragraph.
    static let reportMinBytes = 50

    /// True when report.md is absent or under `reportMinBytes`. Used to
    /// decide whether to give pi a second turn to wrap up.
    public static func reportLooksMissing(sessionDir: URL) -> Bool {
        let url = sessionDir.appending(path: "report.md")
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attrs?[.size] as? Int else { return true }
        return size < reportMinBytes
    }

    /// Soft deadline handed to the wrap-up pi run. Long enough that the
    /// agent doesn't feel rushed into a one-sentence file, short enough
    /// to bound the recovery if pi misbehaves.
    static let wrapUpDeadlineSeconds = 10 * 60

    /// One-shot user message handed to pi when the original run exited
    /// without producing report.md. The agent reconnects via --continue
    /// so it has its full investigation context — this prompt just
    /// names the failure and asks it to fix it.
    public static let wrapUpPrompt = """
        The investigation just finished but report.md in this session directory is missing or empty. Write it now from what you already gathered in this conversation, following the style described in the system prompt: neutral wire-service tone, descriptive section headers, full paragraphs with alias citations and short verbatim quotes (≤30 words) for load-bearing claims, markdown tables for structured data, and open questions plus suggested next steps at the end. Pull the specific phrasing of the documents you read into the report — paraphrase-only paragraphs lose the evidence. Don't open new investigation threads — the report should reflect what you already know. Write the file, then stop.
        """

    /// If report.md is missing after pi exits, give pi one more turn
    /// via --continue and the `wrapUpPrompt`. Best-effort: any error
    /// here is logged but not propagated, since this is a recovery
    /// step and the original run's exit code is what the user asked
    /// about. Skipped when pi crashed (re-running is unlikely to
    /// help), when the user stopped the run, or when report.md is
    /// already substantive.
    private static func runWrapUpIfNeeded(
        sessionDir: URL, session: String,
        originalExitCode: Int32, skillDir: URL,
        legSubdir: String?, debug: Bool,
        logHandle: FileHandle, stamp: @escaping () -> String
    ) async {
        guard originalExitCode == 0 else { return }
        if RunRegistry.read(session)?.status == .stopped { return }
        guard reportLooksMissing(sessionDir: sessionDir) else { return }

        try? logHandle.write(contentsOf: Data(
            "\n\(stamp()) [wrap-up] report.md missing — re-prompting pi\n".utf8
        ))
        do {
            let deadline = Deadline(seconds: wrapUpDeadlineSeconds)
            let prelaunch = try await prepare(
                sessionDir: sessionDir, resuming: true,
                deadline: deadline, skillDir: skillDir,
                legSubdir: legSubdir
            )
            _ = try driveOnePi(
                prelaunch: prelaunch, prompt: wrapUpPrompt, debug: debug,
                logHandle: logHandle, stamp: stamp
            )
            if reportLooksMissing(sessionDir: sessionDir) {
                try? logHandle.write(contentsOf: Data(
                    "\(stamp()) [wrap-up] pi finished but report.md is still missing\n".utf8
                ))
            }
        } catch {
            try? logHandle.write(contentsOf: Data(
                "\(stamp()) [wrap-up] failed: \(error.localizedDescription)\n".utf8
            ))
        }
    }

    /// User prompt handed to pi at the start of every marathon leg
    /// after the first. The system prompt + AGENTS.md already tell the
    /// agent what report.md is for — this just anchors the leg: original
    /// goal, point to durable state, set expectations for depth.
    public static func continuationPrompt(original: String, legNumber: Int) -> String {
        """
        You are continuing this investigation across multiple fresh-context legs. The original task was:

        \(original)

        Your cwd holds your prior work — `report.md` and `findings.db`. Start by reading `report.md` to see what you've established and what threads are still open, then push the investigation deeper: verify weak claims with fresh searches, follow open questions you noted, broaden where useful. Keep updating `report.md` and `findings.db` as you go.

        Anything you read in this leg with `sift read --full` should leave a trace in `report.md` before you stop — a short verbatim quote (≤30 words) plus the alias, or a row in `findings.db` for structured items. The next leg starts with a fresh context and only sees what's on disk; paraphrased summary that drops the source phrasing means the detail is gone.

        This is leg \(legNumber) of the marathon.
        """
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
    /// anything. Prefers `open -ga <path>` over `-gb <bundle-id>` —
    /// path-based open works even when Launch Services hasn't indexed
    /// the freshly-installed bundle yet, which bites every `make install`
    /// → immediate `sift auto` cycle. Idempotent (no-op when the app is
    /// already running). Silently does nothing if Sift.app isn't on
    /// disk; the daemon still runs, the user just won't get the
    /// indicator until they open Sift.app themselves.
    public static func ensureMenuBarRunning() {
        let fm = FileManager.default
        let candidates: [URL] = [
            // CLI inside Sift.app (cask install): walk up to the .app.
            Paths.bundledAppRoot(),
            URL(filePath: "/Applications/Sift.app"),
            URL(filePath: "\(NSHomeDirectory())/Applications/Sift.app"),
        ].compactMap { $0 }
        if let app = candidates.first(where: { fm.fileExists(atPath: $0.path) }) {
            _ = try? Subprocess.run(["/usr/bin/open", "-ga", app.path])
            return
        }
        // No path found — last-ditch ask Launch Services by bundle ID.
        _ = try? Subprocess.run(
            ["/usr/bin/open", "-gb", "eco.datadesk.sift.menubar"]
        )
    }

    /// Timestamp-shaped fallback when no usable slug can be derived
    /// from the user's prompt and they don't supply one interactively.
    public static func fallbackTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: Date())
    }

    /// Append `-2`, `-3`, … if `<researchDir>/<base>` is already taken.
    /// Slugs aren't guaranteed unique across investigations of the same
    /// subject; collisions are rare but real.
    public static func uniqueName(researchDir: URL, base: String) -> String {
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
