import ArgumentParser
import Darwin
import Foundation
import SiftCore

struct AutoCommand: SiftSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "auto",
        abstract: "Run the agent. Returns to the shell once a detached run starts.",
        discussion: """
            With PROMPT, launches a headless one-shot daemon and returns to the
            shell — the menu bar item shows live progress, or use `sift status`
            / `sift logs -f` from the terminal. Without PROMPT, drops into pi's
            interactive REPL (foreground).

            On a fresh lead, sift asks for a slug interactively; pass --slug to
            skip the prompt (required when stdin isn't a TTY).
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
          help: "start a fresh lead instead of continuing the most recent one")
    var new: Bool = false
    @Option(name: .customLong("slug"),
            help: "name for a fresh lead (skips the interactive prompt)")
    var slug: String?

    func execute() async throws {
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
        let mp = try requireVault()
        let researchDir = mp.appending(path: "research")
        try Paths.ensure(researchDir)

        // The active lead wins over "most recent" so the user can pin
        // a particular investigation and have every `sift auto`
        // invocation default back to it. `ActiveLead.get()` already
        // gates on the named dir existing inside the research root,
        // so a renamed / deleted lead falls through to "most recent"
        // rather than silently re-creating an empty session.
        let leadDir: URL? = ActiveLead.get().map { researchDir.appending(path: $0) }

        let canResume = !new && (leadDir != nil
            || PiRunner.mostRecentSession(researchDir: researchDir) != nil)

        let resolution: PiRunner.SessionResolution
        if promptText.isEmpty || canResume {
            // REPL, or detached run that should land on an existing
            // session — let PiRunner pick lead → most-recent → default.
            resolution = PiRunner.resolveSession(
                researchDir: researchDir,
                newSession: new, leadDir: leadDir
            )
        } else {
            // Fresh detached lead — pick a slug (CLI flag, then prompt,
            // then fall back to a timestamp), then suffix `-2`/`-3` if
            // the directory already exists.
            let base = try chooseFreshSlug(explicit: slug, prompt: promptText)
            let name = PiRunner.uniqueName(researchDir: researchDir, base: base)
            resolution = PiRunner.SessionResolution(
                sessionDir: researchDir.appending(path: name),
                resuming: false, staleAge: nil
            )
            // Pin a fresh lead as the active one — that's almost always
            // what the user wants next.
            ActiveLead.set(name)
        }

        // Foreground REPL.
        if promptText.isEmpty {
            Log.say("auto", "session: \(resolution.sessionDir.lastPathComponent)")
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
            let session = resolution.sessionDir.lastPathComponent
            if let stale = resolution.staleAge {
                Log.say("auto", "resuming \(session) (\(stale) since last activity — pass --new if this is a different investigation)")
            } else {
                Log.say("auto", "resuming \(session)")
            }
        }

        // Launch the menu bar app (if installed) so the user sees the
        // run light up immediately rather than having to open it by hand.
        PiRunner.ensureMenuBarRunning()

        let pid = try PiRunner.spawnDaemon(
            sessionDir: resolution.sessionDir, resuming: resolution.resuming,
            prompt: promptText, deadline: deadline, debug: debug
        )
        let session = resolution.sessionDir.lastPathComponent
        Log.say("auto", "started \(session) (pid \(pid))")
        FileHandle.standardError.write(Data(
            "  → live progress: menu bar item, or `sift status` / `sift logs -f`\n".utf8
        ))
    }
}

// MARK: - Slug picker

/// Resolve the slug for a fresh lead. Three sources, in order:
///
///   1. `--slug NAME` — used verbatim (validated, errors fail fast).
///   2. Interactive prompt on a TTY, with the prompt-derived suggestion
///      as the default; bad input re-prompts rather than aborting.
///   3. Non-TTY fallback — the suggestion (or a timestamp if the prompt
///      produced nothing usable). This is what Shortcuts / scripts hit.
func chooseFreshSlug(explicit: String?, prompt: String) throws -> String {
    if let raw = explicit?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
        try SessionName.validate(raw)
        return raw
    }
    let suggested = SessionName.suggest(from: prompt)
    let fallback = suggested.isEmpty ? PiRunner.fallbackTimestamp() : suggested

    let isTTY = isatty(fileno(stdin)) != 0
    if !isTTY { return fallback }

    while true {
        let raw = promptUser("slug for this lead [\(fallback)]:")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = raw.isEmpty ? fallback : raw
        if SessionName.isValid(candidate) {
            return candidate
        }
        FileHandle.standardError.write(Data(
            "  invalid — use letters, digits, '-', '_', '.'\n".utf8
        ))
    }
}

// MARK: - Bundled-resource lookup

/// Locate the SPM-emitted resource bundle next to the running binary.
/// We avoid `Bundle.module` because its lookup is keyed off
/// `Bundle.main.bundleURL`, which doesn't resolve symlinks — so when sift
/// is launched via brew's `/opt/homebrew/bin/sift` symlink the SPM
/// accessor looks in `/opt/homebrew/bin/` instead of the real
/// `Sift.app/Contents/Resources/bin/` and fatal-errors. `Paths.executableDir`
/// resolves the symlink first, so this works under brew-cask installs,
/// `swift run`, and direct `.build/release/sift` invocations alike.
private func siftCLIResourceBundle() -> URL {
    Paths.executableDir.appending(path: "Sift_SiftCLI.bundle")
}

func siftCLIResources() -> SystemPrompt.ResourceURLs {
    // `.copy("Resources")` lands the markdown under
    // <bundle>/Resources/{AGENTS.md, sift/SKILL.md}. The leading
    // "Resources" subdirectory comes from the source-tree layout we
    // told SPM to copy verbatim.
    let resources = siftCLIResourceBundle().appending(path: "Resources")
    let agents = resources.appending(path: "AGENTS.md")
    let skill = resources.appending(path: "sift/SKILL.md")
    let fm = FileManager.default
    return SystemPrompt.ResourceURLs(
        agentsMD: fm.fileExists(atPath: agents.path) ? agents : nil,
        skillMD: fm.fileExists(atPath: skill.path) ? skill : nil
    )
}

func skillDir() -> URL {
    // pi requires the --skill directory's name to match the skill name
    // (i.e. `sift`) and to contain only SKILL.md.
    siftCLIResourceBundle().appending(path: "Resources/sift")
}
