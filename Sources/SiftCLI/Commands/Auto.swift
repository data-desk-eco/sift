import ArgumentParser
import Foundation
import SiftCore

/// `sift auto BRIEF` — fan-out investigation. A thin launcher: unlock the
/// vault, start the local model, inject Aleph creds + paths into the
/// environment, then hand off to the bundled bash orchestrator
/// (`orchestrate.sh`), which spawns one fresh headless pi session per phase
/// and per lead. The new process per lead is the whole context-management
/// strategy — no compaction, no deadline, no run-state sidecar. Run state is
/// plain files under the run dir: `leads.txt` (worklist), `segments/*.md`
/// (per-lead write-ups), `report.md` (the deliverable).
struct AutoCommand: SiftSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "auto",
        abstract: "Plan a worklist from a brief, then sweep it through the collection.",
        discussion: """
            BRIEF is any text or markdown file — a list of topics, or
            freeform instructions. A planning pi session breaks it into a
            worklist (`leads.txt` in the run directory); then, for each lead,
            a fresh pi session searches the collection and writes up what it
            finds under `segments/`. A final session stitches the segments
            into report.md.

            Runs in the foreground: progress streams to the terminal and ^C
            stops the sweep. The write-up lands in report.md inside the run
            directory under the vault. Re-running resumes — leads whose
            segment already exists are skipped.
            """
    )

    @Argument(help: "brief file — a topic list or freeform instructions")
    var list: String

    func execute() async throws {
        let briefURL = URL(filePath: (list as NSString).expandingTildeInPath).absoluteURL
        guard FileManager.default.fileExists(atPath: briefURL.path) else {
            throw SiftError(
                "no brief file at \(list)",
                suggestion: "write topics or instructions into a file, then `sift auto \(list)`"
            )
        }

        try Sift.ensureInitialized()
        SystemPrompt.resourceFinder = { siftCLIResources() }

        let mp = try requireVault()
        let researchDir = mp.appending(path: "research")
        try Paths.ensure(researchDir)
        // Run dir keyed off the brief filename so re-running resumes into the
        // same leads.txt / segments/.
        let base = SessionName.suggest(from: briefURL.deletingPathExtension().lastPathComponent)
        let runDir = researchDir.appending(path: base.isEmpty ? "sweep" : base)
        try Paths.ensure(runDir)

        // Reuse PiRunner.prepare for the careful wiring: llama-server started,
        // backend configured, system prompt built, Aleph creds + shared
        // aleph.sqlite path in the env, vault passphrase stripped.
        let pre = try await PiRunner.prepare(
            sessionDir: runDir, resuming: false, deadline: nil, skillDir: skillDir()
        )
        guard let pi = Paths.findExecutable("pi") else {
            throw SiftError("the pi agent harness isn't installed",
                            suggestion: "re-run the sift installer")
        }
        let script = siftCLIResourceBundle().appending(path: "Resources/orchestrate.sh")

        var env = pre.env
        env["PI_BIN"] = pi
        env["SIFT_SKILL"] = pre.skillDir.path
        env["SIFT_SYSTEM_PROMPT"] = pre.systemPromptPath.path
        // The agent shells out to `sift`; put it on PATH for the run.
        env["PATH"] = Paths.executableDir.path + ":" + (env["PATH"] ?? "")

        Log.say("auto", "sweep \(runDir.lastPathComponent)")
        let p = Process()
        p.executableURL = URL(filePath: "/bin/bash")
        p.arguments = [script.path, runDir.path, briefURL.path]
        p.environment = env
        p.currentDirectoryURL = runDir
        try p.run()
        p.waitUntilExit()

        LlamaServer.stopLocal()
        if p.terminationStatus != 0 {
            throw SiftError(
                "the investigation run exited \(p.terminationStatus)",
                suggestion: "see the output above; re-run to resume from where it stopped"
            )
        }
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
