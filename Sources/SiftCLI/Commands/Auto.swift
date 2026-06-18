import ArgumentParser
import Foundation
import SiftCore

/// `sift auto BRIEF` — turn a freeform brief into a worklist of topics,
/// then sweep them through the collection one fresh agent at a time.
///
/// Phases:
///   0. **plan** — one agent reads the brief and queues a worklist of
///      concrete leads into `topics.txt` (skipped on resume).
///   1. **sweep** — for each topic, a fresh bounded pi session searches,
///      reads, pivots, and records FollowTheMoney findings. Every few
///      topics a consolidation pass distils progress into digest.md,
///      which is fed forward to later sessions.
///   2. **report** — a final agent writes report.md from the findings.
///
/// Each topic gets its own short-lived context so qwen never drags a
/// previous topic's history forward (the slowdown that made the old
/// long-running agent useless on this hardware). findings.db, digest.md,
/// and report.md are shared across the run.
struct AutoCommand: SiftSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "auto",
        abstract: "Plan a worklist from a brief, then sweep it through the collection.",
        discussion: """
            BRIEF is any text or markdown file — a list of topics, or
            freeform instructions. A planning agent breaks it into a
            worklist (`topics.txt` in the run directory); then, for each
            topic, sift boots a fresh pi session bounded by --time-limit
            that searches the collection and records FollowTheMoney
            findings. Agents append new leads with `sift queue`, so the
            sweep grows as it discovers them. When the worklist is dry a
            final agent writes report.md.

            Runs in the foreground: progress streams to the terminal and
            ^C stops the sweep. Findings land in findings.db inside the
            run directory under the vault; upload it to Aleph to thread
            them into the existing entity graph. Re-running resumes —
            already-swept topics stay marked done.
            """
    )

    @Argument(help: "brief file — a topic list or freeform instructions")
    var list: String
    @Option(name: [.short, .customLong("time-limit")],
            help: "per-topic soft deadline (e.g. 20m, 1h); the agent self-paces")
    var timeLimit: String?
    @Flag(name: .customLong("debug"),
          help: "stream raw pi events instead of the filtered terse log")
    var debug: Bool = false

    /// Run a consolidation pass after this many topics complete.
    static let consolidateEvery = 3

    // Hard per-session tool-call backstops. These are runaway guards, not
    // leashes — set well above a healthy session (topics here run ~15-25
    // calls) so the prompt and deadline are the normal stop, and the cap
    // only fires on a session that won't stop itself.
    static let topicMaxSteps = 80
    static let planMaxSteps = 40
    static let metaMaxSteps = 50

    func execute() async throws {
        let perTopic = try timeLimit.map(Deadline.parseDuration) ?? 20 * 60
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

        // The run dir is keyed off the brief filename so re-running the
        // same brief resumes into the same findings.db / topics.txt.
        let base = SessionName.suggest(from: briefURL.deletingPathExtension().lastPathComponent)
        let runDir = researchDir.appending(path: base.isEmpty ? "sweep" : base)
        try Paths.ensure(runDir)
        let topicsURL = runDir.appending(path: "topics.txt")

        // Phase 0 — plan, unless a worklist already exists (resume).
        if !FileManager.default.fileExists(atPath: topicsURL.path) {
            try await plan(brief: briefURL, runDir: runDir, topicsURL: topicsURL)
        }
        guard Worklist.next(at: topicsURL) != nil else {
            LlamaServer.stopLocalIfIdle()
            throw SiftError(
                "no topics to sweep",
                suggestion: "the brief produced an empty worklist, or every topic is already done — delete \(topicsURL.path) to re-plan"
            )
        }

        // Phase 1 — sweep.
        Log.say("auto", "sweep \(runDir.lastPathComponent) — \(Deadline.formatRemaining(perTopic)) per topic")
        var started = 0, done = 0
        while let topic = Worklist.next(at: topicsURL) {
            started += 1
            Log.say("auto", "topic \(started): \(topic)")
            let pre = try await prepareMeta(
                runDir: runDir, topicsURL: topicsURL,
                slug: "t\(started)-\(SessionName.suggest(from: topic))",
                deadline: Deadline(seconds: perTopic)
            )
            let code = try PiRunner.drivePi(
                prelaunch: pre, prompt: topicPrompt(topic, runDir: runDir),
                debug: debug, maxSteps: Self.topicMaxSteps
            )
            if code != 0 { Log.say("auto", "pi exited \(code) on this topic — continuing") }
            Worklist.markDone(at: topicsURL, topic: topic)
            done += 1

            if done % Self.consolidateEvery == 0, Worklist.next(at: topicsURL) != nil {
                try await runMeta(runDir: runDir, topicsURL: topicsURL,
                                  slug: "digest-\(done)", prompt: Self.consolidatePrompt,
                                  note: "consolidating after \(done) topics → digest.md")
            }
        }

        // Phase 2 — final write-up.
        if done > 0 {
            try await runMeta(runDir: runDir, topicsURL: topicsURL,
                              slug: "report", prompt: Self.reportPrompt,
                              note: "writing report.md")
        }

        LlamaServer.stopLocalIfIdle()
        Log.say("auto", "swept \(done) topic(s) — findings.db + report.md in \(runDir.path)")
    }

    // MARK: - Phases

    private func plan(brief: URL, runDir: URL, topicsURL: URL) async throws {
        Log.say("auto", "planning worklist from \(brief.lastPathComponent)")
        let raw = (try? String(contentsOf: brief, encoding: .utf8)) ?? ""
        let pre = try await prepareMeta(
            runDir: runDir, topicsURL: topicsURL, slug: "plan", deadline: nil
        )
        _ = try PiRunner.drivePi(
            prelaunch: pre, prompt: Self.planPrompt(String(raw.prefix(20000))),
            debug: debug, maxSteps: Self.planMaxSteps
        )
    }

    /// Run one non-topic agent (plan / consolidate / report) to completion.
    private func runMeta(
        runDir: URL, topicsURL: URL, slug: String, prompt: String, note: String
    ) async throws {
        Log.say("auto", note)
        let pre = try await prepareMeta(
            runDir: runDir, topicsURL: topicsURL, slug: slug, deadline: nil
        )
        _ = try PiRunner.drivePi(
            prelaunch: pre, prompt: prompt, debug: debug, maxSteps: Self.metaMaxSteps
        )
    }

    /// Shared prelaunch wiring: fresh pi context (`legSubdir`), and the
    /// worklist path exported so any agent can `sift queue` new leads.
    private func prepareMeta(
        runDir: URL, topicsURL: URL, slug: String, deadline: Deadline?
    ) async throws -> PiRunner.Prelaunch {
        var pre = try await PiRunner.prepare(
            sessionDir: runDir, resuming: false,
            deadline: deadline, skillDir: skillDir(),
            legSubdir: slug.isEmpty ? "session" : slug
        )
        pre.env["SIFT_TOPIC_LIST"] = topicsURL.path
        return pre
    }

    // MARK: - Prompts

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

            Search, read what matters, and pivot with `similar` / `expand` / \
            `hubs` to follow the trail. Record findings AS YOU GO: the moment \
            a document establishes a fact — a party, an account, an asset, a \
            payment or an ownership/control link — create the FollowTheMoney \
            entity with `sift entity create … --source <alias>` before your \
            next search, and link related entities by alias (Payment, \
            Ownership, Directorship, UnknownLink, …). Do not batch this to the \
            end. Every document you open with `-f` must leave at least one \
            entity behind — if it wouldn't, you didn't need the full read. A \
            session that searches and reads but records no entities has \
            produced nothing, however much you learned. If a document points \
            to another lead worth its own pass, add it with `sift queue \
            "<lead>"`. Stop when this lead is exhausted or the deadline nears.
            """
        return p
    }

    static func planPrompt(_ brief: String) -> String {
        """
        You're setting up an investigation from the operator's brief (below). \
        Scout the collection briefly — a handful of `sift search` calls (and \
        `sift sources` if you don't know what's loaded) to see which names, \
        entities, and threads return hits and which return nothing. Queue \
        leads AS YOU GO, not at the end: the moment a search confirms an angle \
        is worth a pass, add it with `sift queue "<lead>"` — one call per \
        lead, a single line of plain text (no newlines, keep quotes balanced), \
        specific enough to search but not so granular it fragments. Favour \
        angles that returned promising hits, split a clearly large subject \
        into separate leads, and drop angles the collection has nothing on. \
        This is reconnaissance, not the investigation: keep it to roughly a \
        dozen searches, don't read deeply or record findings, and make sure \
        every lead is queued before you stop — an empty worklist means the \
        run does nothing.

        BRIEF:

        \(brief)
        """
    }

    static let consolidatePrompt = """
        Consolidate this run so far. List the findings recorded with `sift \
        entity list` (and `sift entity show <alias>` where detail helps). \
        Overwrite digest.md with a dense synthesis: what's been established, \
        the entities and names that recur across topics, the strongest \
        threads, and which directions later sessions should prioritise or \
        skip as already covered. Keep it under ~400 words — it is prepended \
        to every subsequent session, so every line has to earn its place. \
        Don't run new searches; synthesise only what's already recorded, \
        then write the file and stop.
        """

    static let reportPrompt = """
        The sweep is complete. Write report.md — the investigation's write-up \
        — from the findings recorded this run. Read them with `sift entity \
        list` and `sift entity show <alias>`: each entity prints its `id:`, \
        and every source line prints its Aleph entity url. Read digest.md for \
        the throughline.

        Write in neutral, wire-service prose: state what the documents show, \
        don't editorialise, don't call anything "major" / "explosive" / \
        "breakthrough", no exclamation marks. Structure it with descriptive \
        section headers and full paragraphs; cite the source alias (e.g. `r4`) \
        inline for each load-bearing claim, and use markdown tables for \
        structured data (parties, dates, amounts).

        The report must stand on its own, so make every reference traceable. \
        End with two tables. **Entities** — every recorded finding, one row \
        per alias with its schema, caption, and `id`. **Sources** — every \
        source alias you cited, with its Aleph entity id and a markdown link \
        to its page, copying the url printed on the source line: \
        `[open](<that url>)`. Then close with the open questions and suggested \
        next steps a reporter would need to take it further. Write the file, \
        then stop.
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
