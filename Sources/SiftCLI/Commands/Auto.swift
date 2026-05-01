import ArgumentParser
import Darwin
import Foundation
import SiftCore

struct AutoCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "auto",
        abstract: "Run the agent. Returns to the shell once a detached run starts.",
        discussion: """
            With PROMPT, launches a headless one-shot daemon and returns to the
            shell — the menu bar item shows live progress, or use `sift status`
            / `sift logs -f` from the terminal. Without PROMPT, drops into pi's
            interactive REPL (foreground).
            """
    )

    @Argument(help: "what to investigate (omit to drop into pi's REPL)")
    var prompt: [String] = []
    @Flag(name: .customLong("debug"),
          help: "log raw pi events instead of the filtered terse log")
    var debug: Bool = false
    @Option(name: [.short, .customLong("time-limit")],
            help: "soft deadline (e.g. 30m, 1h30m, 90s); the agent self-paces")
    var timeLimit: String?
    @Flag(name: [.short, .customLong("new")],
          help: "start a fresh session instead of continuing the most recent one")
    var new: Bool = false

    func run() async throws {
        do {
            try await execute()
        } catch {
            throw ExitCode(reportSiftError(error))
        }
    }

    private func execute() async throws {
        // Parse the deadline first so a bad value fails fast, before
        // any vault unlock or backend startup happens.
        let deadline: Deadline?
        if let raw = timeLimit {
            let seconds = try Deadline.parseDuration(raw)
            deadline = Deadline(seconds: seconds)
        } else {
            deadline = nil
        }

        try Sift.ensureInitialized()
        SystemPrompt.resourceFinder = { siftCLIResources() }

        let promptText = prompt.joined(separator: " ")

        // If interactive REPL: figure out resume / fresh; build prelaunch; execve into pi.
        let vault = VaultService()
        let mp = try (vault.findExistingMount() ?? vault.unlock())
        let researchDir = mp.appending(path: "research")
        try Paths.ensure(researchDir)

        // The active lead — if set and still on disk — wins over
        // "most recent" so the user can pin a particular investigation
        // and have every `sift auto` invocation default back to it.
        let leadDir: URL? = ActiveLead.get().flatMap { name in
            let candidate = researchDir.appending(path: name)
            return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
        }

        let resolution: PiRunner.SessionResolution
        if promptText.isEmpty {
            // REPL: continue active lead, else most recent, unless --new.
            if !new, let lead = leadDir {
                resolution = PiRunner.SessionResolution(
                    sessionDir: lead, resuming: true, staleAge: nil
                )
            } else {
                resolution = PiRunner.resolveSession(
                    researchDir: researchDir, prompt: nil,
                    newSession: new, freshSlug: nil
                )
            }
        } else if !new, let lead = leadDir {
            // Detached run against the active lead.
            resolution = PiRunner.SessionResolution(
                sessionDir: lead, resuming: true, staleAge: nil
            )
        } else if !new, let last = PiRunner.mostRecentSession(researchDir: researchDir) {
            // Detached resume.
            let lastMod = PiRunner.lastModified(of: last)
            let ageH = (Date().timeIntervalSince1970 - lastMod) / 3600
            let stale = ageH >= Double(PiRunner.staleSessionHours)
                ? PiRunner.formatAge(ageH) : nil
            resolution = PiRunner.SessionResolution(
                sessionDir: last, resuming: true, staleAge: stale
            )
        } else {
            // New detached session — name it via AI slug (or regex fallback).
            let name = await PiRunner.newSessionName(prompt: promptText, researchDir: researchDir)
            resolution = PiRunner.SessionResolution(
                sessionDir: researchDir.appending(path: name),
                resuming: false, staleAge: nil
            )
            // Pin a fresh session as the active lead — that's almost
            // always what the user wants next.
            ActiveLead.set(name)
        }

        // Foreground REPL.
        if promptText.isEmpty {
            FileHandle.standardError.write(Data(
                "[auto]     session: \(resolution.sessionDir.lastPathComponent)\n".utf8
            ))
            let prelaunch = try await PiRunner.prepare(
                sessionDir: resolution.sessionDir, resuming: resolution.resuming,
                deadline: deadline, skillDir: skillDir()
            )
            // chdir into session dir so pi's relative writes (report.md) land
            // inside the encrypted volume.
            FileManager.default.changeCurrentDirectoryPath(prelaunch.sessionDir.path)
            PiRunner.execReplaceWithPi(prelaunch: prelaunch)
        }

        // Detached one-shot.
        if resolution.resuming {
            if let stale = resolution.staleAge {
                FileHandle.standardError.write(Data(
                    "[auto]     resuming \(resolution.sessionDir.lastPathComponent) (\(stale) since last activity — pass --new if this is a different investigation)\n".utf8
                ))
            } else {
                FileHandle.standardError.write(Data(
                    "[auto]     resuming \(resolution.sessionDir.lastPathComponent)\n".utf8
                ))
            }
        }

        // Launch the menu bar app (if installed) so the user sees the
        // run light up immediately rather than having to open it by hand.
        PiRunner.ensureMenuBarRunning()

        try await spawnDaemon(
            sessionDir: resolution.sessionDir, resuming: resolution.resuming,
            prompt: promptText, deadline: deadline, debug: debug
        )
    }

    /// Re-exec the current binary as `sift _daemon ...` with setsid so the
    /// resulting process survives our exit, then return to the shell.
    private func spawnDaemon(
        sessionDir: URL, resuming: Bool,
        prompt: String, deadline: Deadline?, debug: Bool
    ) async throws {
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

        let session = sessionDir.lastPathComponent
        FileHandle.standardError.write(Data(
            "[auto]     started \(session) (pid \(pid))\n".utf8
        ))
        FileHandle.standardError.write(Data(
            "  → live progress: menu bar item, or `sift status` / `sift logs -f`\n".utf8
        ))
    }
}

// MARK: - Bundled-resource lookup

func siftCLIResources() -> SystemPrompt.ResourceURLs {
    // `.copy("Resources")` lands the markdown under
    // <bundle>/Resources/{AGENTS.md, sift/SKILL.md}. The leading
    // "Resources" subdirectory comes from the source-tree layout we
    // told SPM to copy verbatim.
    SystemPrompt.ResourceURLs(
        agentsMD: Bundle.module.url(
            forResource: "AGENTS", withExtension: "md", subdirectory: "Resources"
        ),
        skillMD: Bundle.module.url(
            forResource: "SKILL", withExtension: "md", subdirectory: "Resources/sift"
        )
    )
}

func skillDir() -> URL {
    // pi requires the --skill directory's name to match the skill name
    // (i.e. `sift`) and to contain only SKILL.md.
    let bundle = Bundle.module
    if let url = bundle.url(
        forResource: "sift", withExtension: nil, subdirectory: "Resources"
    ) {
        return url
    }
    // Fallback (shouldn't hit in production builds): synthesise it.
    return bundle.bundleURL.appending(path: "Resources/sift")
}
