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

            Starts a new lead by default and asks for a slug interactively;
            pass --resume to continue the active lead (or the most recent one)
            instead. Pass --slug NAME to skip the slug prompt (required when
            stdin isn't a TTY).
            """
    )

    @Argument(help: "what to investigate (omit to drop into pi's REPL)")
    var prompt: [String] = []
    @Flag(name: .customLong("debug"),
          help: "log raw pi events instead of the filtered terse log")
    var debug: Bool = false
    @Option(name: [.short, .customLong("time-limit")],
            help: "soft deadline (e.g. 30m, 1h30m, 90s); the agent self-paces. With --marathon this is the per-leg budget (default 30m).")
    var timeLimit: String?
    @Option(name: .customLong("marathon"),
            help: "run as a marathon: loop multiple fresh-context legs for up to this total budget (e.g. 4h). Each leg gets its own deadline (--time-limit); between legs the context is reset and the agent continues from report.md / findings.db.")
    var marathon: String?
    @Flag(name: [.short, .customLong("resume")],
          help: "continue the active lead (or most recent) instead of starting fresh")
    var resume: Bool = false
    @Option(name: .customLong("slug"),
            help: "name for a fresh lead (skips the interactive prompt)")
    var slug: String?

    func execute() async throws {
        // Parse all durations first so a bad value fails fast, before
        // any vault unlock or backend startup happens.
        let marathonSeconds: Int?
        if let raw = marathon {
            marathonSeconds = try Deadline.parseDuration(raw)
        } else {
            marathonSeconds = nil
        }
        // Marathon runs need a meaningful per-leg budget — without one
        // the agent has no pacing signal and either burns out fast or
        // never wraps a leg cleanly. Default to 30m, which is roughly
        // where pi's context starts to feel its weight.
        let legSeconds: Int?
        if let raw = timeLimit {
            legSeconds = try Deadline.parseDuration(raw)
        } else if marathonSeconds != nil {
            legSeconds = 30 * 60
        } else {
            legSeconds = nil
        }
        // Foreground REPL doesn't loop legs — marathon only makes sense
        // for the detached headless path where the daemon can outlive
        // the user's terminal.
        if marathon != nil, prompt.isEmpty {
            throw SiftError(
                "--marathon needs a PROMPT — it's a headless-only mode",
                suggestion: "`sift auto \"your goal\" --marathon 4h`"
            )
        }
        if let total = marathonSeconds, let leg = legSeconds, total <= leg {
            throw SiftError(
                "--marathon \(marathon!) is not longer than the leg time \(timeLimit ?? "30m")",
                suggestion: "make the marathon budget at least 2× the leg time, or drop --marathon"
            )
        }
        let deadline: Deadline?
        if let seconds = legSeconds {
            deadline = Deadline(seconds: seconds)
        } else {
            deadline = nil
        }
        let marathonEnd: Int? = marathonSeconds.map {
            Int(Date().timeIntervalSince1970) + $0
        }

        try Sift.ensureInitialized()
        SystemPrompt.resourceFinder = { siftCLIResources() }

        let promptText = prompt.joined(separator: " ")

        let mp = try requireVault()
        let researchDir = mp.appending(path: "research")
        try Paths.ensure(researchDir)

        // --resume picks the user's pinned lead first, then falls back to the
        // most recent session on disk. `ActiveLead.get()` already gates on the
        // named dir existing inside the research root, so a renamed / deleted
        // lead falls through to "most recent" rather than silently re-creating
        // an empty session under the stale name.
        let leadDir: URL? = ActiveLead.get().map { researchDir.appending(path: $0) }

        let resolution: PiRunner.SessionResolution
        if resume {
            let candidate = PiRunner.resolveSession(
                researchDir: researchDir, newSession: false, leadDir: leadDir
            )
            if candidate.resuming {
                resolution = candidate
            } else {
                // -r with nothing on disk to resume — fall through to a fresh
                // lead so the command still does what the user meant rather
                // than aborting on a clean install.
                Log.say("auto", "no lead to resume — starting a new one")
                resolution = try freshLead(
                    researchDir: researchDir, prompt: promptText
                )
            }
        } else {
            resolution = try freshLead(
                researchDir: researchDir, prompt: promptText
            )
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
                Log.say("auto", "resuming \(session) (\(stale) since last activity — drop --resume if this is a different investigation)")
            } else {
                Log.say("auto", "resuming \(session)")
            }
        }

        // Launch the menu bar app (if installed) so the user sees the
        // run light up immediately rather than having to open it by hand.
        PiRunner.ensureMenuBarRunning()

        let pid = try PiRunner.spawnDaemon(
            sessionDir: resolution.sessionDir, resuming: resolution.resuming,
            prompt: promptText, deadline: deadline,
            marathonEnd: marathonEnd, debug: debug
        )
        let session = resolution.sessionDir.lastPathComponent
        if marathonEnd != nil {
            let total = Deadline.formatRemaining(marathonSeconds ?? 0)
            let leg = Deadline.formatRemaining(legSeconds ?? 0)
            Log.say("auto", "started \(session) — marathon (\(total) total, \(leg) per leg, pid \(pid))")
        } else {
            Log.say("auto", "started \(session) (pid \(pid))")
        }
        FileHandle.standardError.write(Data(
            "  → live progress: menu bar item, or `sift status` / `sift logs -f`\n".utf8
        ))
    }
}

extension AutoCommand {
    /// Build a fresh `SessionResolution`: pick a slug (CLI flag → derived
    /// from prompt → interactive prompt → timestamp), suffix `-2`/`-3` on
    /// collision, and pin the new lead as the active one.
    fileprivate func freshLead(
        researchDir: URL, prompt: String
    ) throws -> PiRunner.SessionResolution {
        let base = try chooseFreshSlug(explicit: slug, prompt: prompt)
        let name = PiRunner.uniqueName(researchDir: researchDir, base: base)
        let sessionDir = researchDir.appending(path: name)
        // Create the dir before pinning the lead — `ActiveLead.get()`
        // gates on `sessionDir` existing, and the daemon doesn't create
        // it until after llama-server has warmed (seconds to minutes on
        // a cold model load). Without this, `sift status`, `sift logs`,
        // and `sift stop` all see "no active lead" right after launch.
        try Paths.ensure(sessionDir)
        ActiveLead.set(name)
        return PiRunner.SessionResolution(
            sessionDir: sessionDir,
            resuming: false, staleAge: nil
        )
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
