import Darwin
import Foundation

/// Environment wiring for `sift auto`. `prepare()` starts the local model,
/// configures the backend, builds the system prompt, and assembles the env
/// (Aleph creds, shared aleph.sqlite path, pi config) that the bash
/// orchestrator hands to each headless pi session it spawns. No daemon, no
/// run-state sidecar — `leads.txt` and the per-lead segments are the state.
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

    // MARK: - Helpers

    /// pi is installed by sift's installer into Application Support; the
    /// CLI also looks on $PATH as a fallback for ad-hoc dev installs.
    private static func requirePi() throws {
        if Paths.findExecutable("pi") != nil { return }
        throw SiftError(
            "the pi agent harness isn't installed",
            suggestion: "re-run the sift installer, or `make install-pi` from a source checkout"
        )
    }

    private static func localTimeShort(_ ts: Int) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }
}
