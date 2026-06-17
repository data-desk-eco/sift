import ArgumentParser
import Foundation
import SiftCore

/// `sift auto LIST.txt` — sweep a worklist of topics through the
/// collection, one fresh-context pi session per topic, in sequence.
///
/// Each topic gets a bounded session so qwen never drags a previous
/// topic's context into the next (the slowdown that made the old
/// long-running agent useless on this hardware). Findings accumulate as
/// FollowTheMoney entities in a single findings.db shared across the
/// run; the agent appends new leads to the same worklist via `sift
/// queue`. Every few topics a consolidation pass distils what's been
/// found into digest.md, which is fed forward into later sessions.
struct AutoCommand: SiftSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "auto",
        abstract: "Sweep a list of topics through the collection, one agent per topic.",
        discussion: """
            LIST is a plain text file, one topic per line (blank lines and
            `#` comments ignored). For each topic, sift boots a fresh pi
            session bounded by --time-limit, lets it search/read/pivot and
            record FollowTheMoney findings, then marks the line done with a
            leading `✓`. The agent can append new topics to the same file
            with `sift queue`, so the sweep grows as it discovers leads.

            Runs in the foreground: progress streams to the terminal and
            ^C stops the sweep. Findings land in findings.db and report.md
            inside the run directory under the vault; upload findings.db to
            Aleph to thread them into the existing entity graph.
            """
    )

    @Argument(help: "worklist file — one topic per line")
    var list: String
    @Option(name: [.short, .customLong("time-limit")],
            help: "per-topic soft deadline (e.g. 20m, 1h); the agent self-paces")
    var timeLimit: String?
    @Flag(name: .customLong("debug"),
          help: "stream raw pi events instead of the filtered terse log")
    var debug: Bool = false

    /// Run a consolidation pass after this many topics complete.
    static let consolidateEvery = 3
    /// Budget for the consolidation pass — it only reads disk, no searches.
    static let consolidateSeconds = 10 * 60

    func execute() async throws {
        let perTopic = try timeLimit.map(Deadline.parseDuration) ?? 20 * 60
        let listURL = URL(filePath: (list as NSString).expandingTildeInPath).absoluteURL
        guard FileManager.default.fileExists(atPath: listURL.path) else {
            throw SiftError(
                "no worklist file at \(list)",
                suggestion: "create it with one topic per line, then `sift auto \(list)`"
            )
        }

        try Sift.ensureInitialized()
        SystemPrompt.resourceFinder = { siftCLIResources() }

        let mp = try requireVault()
        let researchDir = mp.appending(path: "research")
        try Paths.ensure(researchDir)

        // The run dir is keyed off the worklist filename so re-running the
        // same list accumulates into the same findings.db / report.md.
        let base = SessionName.suggest(from: listURL.deletingPathExtension().lastPathComponent)
        let runDir = researchDir.appending(path: base.isEmpty ? "sweep" : base)
        try Paths.ensure(runDir)
        Log.say("auto", "sweep \(runDir.lastPathComponent) — \(Deadline.formatRemaining(perTopic)) per topic")

        var started = 0, done = 0
        while let topic = Worklist.next(at: listURL) {
            started += 1
            Log.say("auto", "topic \(started): \(topic)")
            let prelaunch = try await prepareTopic(
                runDir: runDir, listURL: listURL,
                slug: "t\(started)-\(SessionName.suggest(from: topic))",
                seconds: perTopic
            )
            let code = try PiRunner.drivePi(
                prelaunch: prelaunch, prompt: topicPrompt(topic, runDir: runDir),
                debug: debug
            )
            if code != 0 { Log.say("auto", "pi exited \(code) on this topic — continuing") }
            Worklist.markDone(at: listURL, topic: topic)
            done += 1

            if done % Self.consolidateEvery == 0, Worklist.next(at: listURL) != nil {
                try await consolidate(runDir: runDir, after: done)
            }
        }

        // Free the model from unified memory now the sweep is done.
        LlamaServer.stopLocalIfIdle()
        Log.say("auto", "swept \(done) topic(s) — findings.db + report.md in \(runDir.path)")
    }

    // MARK: - One topic

    private func prepareTopic(
        runDir: URL, listURL: URL, slug: String, seconds: Int
    ) async throws -> PiRunner.Prelaunch {
        var pre = try await PiRunner.prepare(
            sessionDir: runDir, resuming: false,
            deadline: Deadline(seconds: seconds), skillDir: skillDir(),
            legSubdir: slug
        )
        // So the agent can `sift queue` new leads onto this run's worklist.
        pre.env["SIFT_TOPIC_LIST"] = listURL.path
        return pre
    }

    private func topicPrompt(_ topic: String, runDir: URL) -> String {
        var p = ""
        let digest = runDir.appending(path: "digest.md")
        if let d = try? String(contentsOf: digest, encoding: .utf8),
           !d.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            p += "What earlier sessions in this run have established:\n\n\(d)\n\n---\n\n"
        }
        p += """
            Investigate this lead against the collection:

                \(topic)

            Search broadly, read what matters, and pivot with `similar` / \
            `expand` / `hubs` to follow the trail. Record every solid finding \
            as a FollowTheMoney entity with `sift entity create`, citing the \
            source document(s) with `--source`; link related parties with edge \
            schemas (Ownership, Payment, UnknownLink, …) where the relationship \
            is clear. Keep a running narrative in report.md. If you surface \
            other leads worth investigating, add each with `sift queue "<lead>"`. \
            Stop when you've exhausted this lead or the deadline nears.
            """
        return p
    }

    // MARK: - Consolidation pass

    /// Every few topics, a fresh session reads what's on disk and writes a
    /// dense digest.md. It carries no topic of its own — its job is to
    /// give later sessions cross-topic memory without dragging the full
    /// history into their context.
    private func consolidate(runDir: URL, after n: Int) async throws {
        Log.say("auto", "consolidating after \(n) topics → digest.md")
        let pre = try await PiRunner.prepare(
            sessionDir: runDir, resuming: false,
            deadline: Deadline(seconds: Self.consolidateSeconds), skillDir: skillDir(),
            legSubdir: "digest-\(n)"
        )
        _ = try PiRunner.drivePi(prelaunch: pre, prompt: Self.consolidatePrompt, debug: debug)
    }

    static let consolidatePrompt = """
        Consolidate this run so far. Read report.md and list the structured \
        findings (`sift entity list`). Then overwrite digest.md with a dense \
        synthesis: what's been established, the strongest threads, the names \
        and entities that recur across topics, and which directions later \
        sessions should prioritise or skip as already covered. Keep it under \
        ~400 words — it is prepended to every subsequent session's prompt, so \
        every line has to earn its place. Don't run new searches; synthesise \
        only what's already on disk, then write the file and stop.
        """
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
