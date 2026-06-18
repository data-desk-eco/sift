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
///      reads, pivots, and writes up what it finds as a markdown segment
///      under `segments/`. Every few topics a consolidation pass distils
///      progress into digest.md, which is fed forward to later sessions.
///   2. **report** — a final agent stitches the segments into report.md,
///      reviewing for overlap and contradictions as it goes.
///
/// Each topic gets its own short-lived context so qwen never drags a
/// previous topic's history forward (the slowdown that made the old
/// long-running agent useless on this hardware). segments/, digest.md,
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
            that searches the collection and writes up what it finds as a
            markdown segment under `segments/`. Agents append new leads
            with `sift queue`, so the sweep grows as it discovers them.
            When the worklist is dry a final agent stitches the segments
            into report.md.

            Runs in the foreground: progress streams to the terminal and
            ^C stops the sweep. The write-up lands in report.md inside the
            run directory under the vault. Re-running resumes —
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

    /// Soft deadline for the recon plan phase, capped at the per-topic
    /// budget so a tight `-t` bounds planning too. Soft only — it nudges
    /// the planner to scope and stop, it doesn't kill the session.
    static let planSeconds = 10 * 60

    // Hard per-session tool-call backstops. These are runaway guards, not
    // leashes — set well above a healthy session (topics here run ~15-25
    // calls) so the prompt and deadline are the normal stop, and the cap
    // only fires on a session that won't stop itself. The plan phase is
    // uncapped: it's reconnaissance plus one `sift queue` call per lead,
    // so a healthy run easily clears 40, and it's foreground-supervised.
    static let topicMaxSteps = 80
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
        // same brief resumes into the same segments/ / topics.txt.
        let base = SessionName.suggest(from: briefURL.deletingPathExtension().lastPathComponent)
        let runDir = researchDir.appending(path: base.isEmpty ? "sweep" : base)
        try Paths.ensure(runDir)
        let topicsURL = runDir.appending(path: "topics.txt")
        let segmentsDir = runDir.appending(path: "segments")
        try Paths.ensure(segmentsDir)

        // Phase 0 — plan, unless a worklist already exists (resume).
        if !FileManager.default.fileExists(atPath: topicsURL.path) {
            try await plan(brief: briefURL, runDir: runDir, topicsURL: topicsURL,
                           deadline: Deadline(seconds: min(perTopic, Self.planSeconds)))
            // The planner queues leads via `sift queue`, but its generic
            // file tool can clobber the visible worklist (it once cut 16
            // queued leads to 3). Rebuild topics.txt from the hidden
            // ledger so every queued lead reaches the sweep.
            Worklist.rebuildFromLedger(at: topicsURL)
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
            let slug = "t\(started)-\(SessionName.suggest(from: topic))"
            let segment = segmentsDir.appending(path: "\(slug).md")
            let pre = try await prepareMeta(
                runDir: runDir, topicsURL: topicsURL, slug: slug,
                deadline: Deadline(seconds: perTopic), segment: segment
            )
            let r = try PiRunner.drivePi(
                prelaunch: pre, prompt: topicPrompt(topic, runDir: runDir, segment: segment),
                debug: debug, maxSteps: Self.topicMaxSteps
            )
            if r.code != 0 { Log.say("auto", "pi exited \(r.code) on this topic — continuing") }
            if !Self.captureIfMissing(segment, finalText: r.finalText) {
                Log.say("auto", "topic \(started) wrote no segment — nothing to report from it")
            }
            Worklist.markDone(at: topicsURL, topic: topic)
            done += 1

            if done % Self.consolidateEvery == 0, Worklist.next(at: topicsURL) != nil {
                try await runMeta(runDir: runDir, topicsURL: topicsURL,
                                  slug: "digest-\(done)", prompt: Self.consolidatePrompt,
                                  note: "consolidating after \(done) topics → digest.md",
                                  target: runDir.appending(path: "digest.md"))
            }
        }

        // Phase 2 — final write-up.
        let report = runDir.appending(path: "report.md")
        if done > 0 {
            try await runMeta(runDir: runDir, topicsURL: topicsURL,
                              slug: "report", prompt: Self.reportPrompt,
                              note: "writing report.md", target: report)
        }

        LlamaServer.stopLocalIfIdle()
        if Self.hasContent(report) {
            Log.say("auto", "swept \(done) topic(s) — report.md in \(runDir.path)")
        } else {
            let n = ((try? FileManager.default.contentsOfDirectory(atPath: segmentsDir.path)) ?? [])
                .filter { $0.hasSuffix(".md") }.count
            Log.say("auto", "swept \(done) topic(s) — no report.md written; \(n) segment(s) in \(segmentsDir.path)")
        }
    }

    // MARK: - Deliverable capture

    /// True if `url` exists and holds non-whitespace content.
    static func hasContent(_ url: URL) -> Bool {
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return false }
        return !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Guarantee the deliverable exists. The weak local model sometimes
    /// investigates thoroughly but ends the turn without ever writing its
    /// file — when that happens we salvage its closing prose as the file
    /// so a phase that did the work still leaves something behind. Returns
    /// whether the file ended up non-empty.
    @discardableResult
    static func captureIfMissing(_ url: URL, finalText: String) -> Bool {
        if hasContent(url) { return true }
        let t = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        try? t.write(to: url, atomically: true, encoding: .utf8)
        return true
    }

    // MARK: - Phases

    private func plan(brief: URL, runDir: URL, topicsURL: URL, deadline: Deadline) async throws {
        Log.say("auto", "planning worklist from \(brief.lastPathComponent) — \(Deadline.formatRemaining(deadline.remainingSeconds)) budget")
        let raw = (try? String(contentsOf: brief, encoding: .utf8)) ?? ""
        let pre = try await prepareMeta(
            runDir: runDir, topicsURL: topicsURL, slug: "plan", deadline: deadline,
            deadlineKind: .plan
        )
        _ = try PiRunner.drivePi(
            prelaunch: pre, prompt: Self.planPrompt(String(raw.prefix(20000))),
            debug: debug, maxSteps: nil
        )
    }

    /// Run one non-topic agent (consolidate / report) to completion. When
    /// `target` is given, fall back to the agent's closing prose if it
    /// never wrote the file itself.
    private func runMeta(
        runDir: URL, topicsURL: URL, slug: String, prompt: String, note: String,
        target: URL? = nil
    ) async throws {
        Log.say("auto", note)
        let pre = try await prepareMeta(
            runDir: runDir, topicsURL: topicsURL, slug: slug, deadline: nil
        )
        let r = try PiRunner.drivePi(
            prelaunch: pre, prompt: prompt, debug: debug, maxSteps: Self.metaMaxSteps
        )
        if let target { Self.captureIfMissing(target, finalText: r.finalText) }
    }

    /// Shared prelaunch wiring: fresh pi context (`legSubdir`), and the
    /// worklist path exported so any agent can `sift queue` new leads.
    private func prepareMeta(
        runDir: URL, topicsURL: URL, slug: String, deadline: Deadline?,
        segment: URL? = nil,
        deadlineKind: SystemPrompt.DeadlineNote.Kind = .investigate
    ) async throws -> PiRunner.Prelaunch {
        var pre = try await PiRunner.prepare(
            sessionDir: runDir, resuming: false,
            deadline: deadline, skillDir: skillDir(),
            legSubdir: slug.isEmpty ? "session" : slug,
            deadlineKind: deadlineKind
        )
        pre.env["SIFT_TOPIC_LIST"] = topicsURL.path
        if let segment { pre.env["SIFT_SEGMENT"] = segment.path }
        return pre
    }

    // MARK: - Prompts

    private func topicPrompt(_ topic: String, runDir: URL, segment: URL) -> String {
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
            `hubs` to follow the trail. Write your findings up AS YOU GO into \
            `\(segment.path)` — your segment of the final report. The moment a \
            document establishes something — a party, an account, an asset, a \
            payment or an ownership/control link — append a sentence or two in \
            neutral, wire-service prose, citing the source alias (`r4`) inline \
            so every claim stays traceable. Don't batch this to the end. Open \
            the section with a `## ` heading naming the lead. Every document \
            you open with `-f` must leave something behind in the segment — if \
            it wouldn't, you didn't need the full read. A session that searches \
            and reads but writes nothing has produced nothing, however much you \
            learned. If a document points to another lead worth its own pass, \
            add it with `sift queue "<lead>"`. Stop when this lead is exhausted \
            or the deadline nears.
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
        specific enough to search but not so granular it fragments. Each \
        `queue` call confirms the add (or tells you it's already there), so \
        queue each lead once and move on — don't re-add or cat the file to \
        check. Favour \
        angles that returned promising hits, split a clearly large subject \
        into separate leads, and drop angles the collection has nothing on. \
        This is reconnaissance, not the investigation: keep it to roughly a \
        dozen searches, don't read deeply or write anything up, and make sure \
        every lead is queued before you stop — an empty worklist means the \
        run does nothing.

        BRIEF:

        \(brief)
        """
    }

    static let consolidatePrompt = """
        Consolidate this run so far. Read every segment under `segments/` (each \
        is one lead's write-up). Overwrite digest.md with a dense synthesis: \
        what's been established, the parties and names that recur across leads, \
        the strongest threads, and which directions later sessions should \
        prioritise or skip as already covered. Keep it under ~400 words — it is \
        prepended to every subsequent session, so every line has to earn its \
        place. Don't run new searches; synthesise only what the segments \
        already say, then write the file and stop.
        """

    static let reportPrompt = """
        The sweep is complete. Write report.md — the investigation's write-up \
        — by stitching together the per-lead segments under `segments/`. Read \
        every segment and digest.md for the throughline, then weave them into \
        one coherent report: merge what overlaps, fold duplicated parties into \
        a single account, flag where two segments contradict each other, and \
        order the material so it reads as one investigation rather than a pile \
        of leads.

        Write in neutral, wire-service prose: state what the documents show, \
        don't editorialise, don't call anything "major" / "explosive" / \
        "breakthrough", no exclamation marks. Structure it with descriptive \
        section headers and full paragraphs; carry through the source alias \
        (e.g. `r4`) the segments cite for each load-bearing claim, and use \
        markdown tables for structured data (parties, dates, amounts).

        The report must stand on its own, so make every reference traceable. \
        End with a **Sources** table — every source alias cited across the \
        report, one row each, with a short note of what it is. To turn an \
        alias into a link, `sift read <alias>` prints its Aleph entity url; \
        use `[open](<that url>)`. Then close with the open questions and \
        suggested next steps a reporter would need to take it further. Write \
        the file, then stop.
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
