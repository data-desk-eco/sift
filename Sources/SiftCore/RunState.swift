import Foundation

/// Persisted state for a running (or recently finished) `sift auto`
/// daemon. The JSON sidecar lives at `<sessionDir>/.sift-run.json`,
/// inside the encrypted vault — renaming the session directory
/// renames the session as far as the CLI and the menu bar are
/// concerned, because identity (`session`, `sessionDir`, `logPath`)
/// is derived from the on-disk path at read time, not stored.
///
/// The CLI's `sift status` / `sift logs` / `sift stop` and the menu
/// bar app all read from these sidecars; the menu bar also watches
/// the research directory via DispatchSource for live updates.
public struct RunState: Sendable {
    public enum Status: String, Codable, Sendable {
        case running, finished, failed, stopped
    }

    // Identity — derived from the sidecar's on-disk location, not
    // persisted. Read code populates them after decoding the payload.
    public var session: String
    public var sessionDir: String
    public var logPath: String

    // Persisted fields.
    public var prompt: String
    public var pid: Int32
    public var startedAt: Int
    public var deadlineTs: Int?
    public var deadlineStartTs: Int?
    public var status: Status
    public var lastScope: String
    public var lastMessage: String
    public var lastEventAt: Int
    public var exitCode: Int32?
    public var finishedAt: Int?

    public init(
        session: String, sessionDir: String, logPath: String,
        prompt: String, pid: Int32, startedAt: Int,
        deadlineTs: Int? = nil, deadlineStartTs: Int? = nil
    ) {
        self.session = session
        self.sessionDir = sessionDir
        self.logPath = logPath
        self.prompt = prompt
        self.pid = pid
        self.startedAt = startedAt
        self.deadlineTs = deadlineTs
        self.deadlineStartTs = deadlineStartTs
        self.status = .running
        self.lastScope = ""
        self.lastMessage = ""
        self.lastEventAt = startedAt
        self.exitCode = nil
        self.finishedAt = nil
    }

    fileprivate init(payload: RunStatePayload, sessionDir: URL) {
        self.session = sessionDir.lastPathComponent
        self.sessionDir = sessionDir.path
        self.logPath = sessionDir.appending(path: "auto.log").path
        self.prompt = payload.prompt
        self.pid = payload.pid
        self.startedAt = payload.startedAt
        self.deadlineTs = payload.deadlineTs
        self.deadlineStartTs = payload.deadlineStartTs
        self.status = payload.status
        self.lastScope = payload.lastScope
        self.lastMessage = payload.lastMessage
        self.lastEventAt = payload.lastEventAt
        self.exitCode = payload.exitCode
        self.finishedAt = payload.finishedAt
    }
}

/// On-disk shape of the sidecar. Excludes session/sessionDir/logPath
/// — those are reconstructed from the file's parent path so a
/// renamed directory transparently renames the session.
private struct RunStatePayload: Codable {
    var prompt: String
    var pid: Int32
    var startedAt: Int
    var deadlineTs: Int?
    var deadlineStartTs: Int?
    var status: RunState.Status
    var lastScope: String
    var lastMessage: String
    var lastEventAt: Int
    var exitCode: Int32?
    var finishedAt: Int?

    init(from state: RunState) {
        self.prompt = state.prompt
        self.pid = state.pid
        self.startedAt = state.startedAt
        self.deadlineTs = state.deadlineTs
        self.deadlineStartTs = state.deadlineStartTs
        self.status = state.status
        self.lastScope = state.lastScope
        self.lastMessage = state.lastMessage
        self.lastEventAt = state.lastEventAt
        self.exitCode = state.exitCode
        self.finishedAt = state.finishedAt
    }
}

public enum RunRegistry {
    /// Filename of the per-session sidecar. Hidden so it doesn't clutter
    /// the user's view of the session dir in Finder.
    static let sidecarName = ".sift-run.json"

    /// Where session directories live. ALEPH_SESSION_DIR wins (set in
    /// the daemon's env, and used by tests to point at a tmp dir);
    /// otherwise the mounted vault's `research/`. Returns nil when
    /// nothing is reachable — callers treat that as "no sessions" rather
    /// than prompting the user to unlock.
    public static func researchRoot() -> URL? {
        if let env = ProcessInfo.processInfo.environment["ALEPH_SESSION_DIR"],
           !env.isEmpty {
            return URL(filePath: env)
        }
        if let mp = VaultService().findExistingMount() {
            return mp.appending(path: "research")
        }
        return nil
    }

    public static func sidecarURL(for sessionDir: URL) -> URL {
        sessionDir.appending(path: sidecarName)
    }

    public static func write(_ state: RunState) throws {
        try SessionName.validate(state.session)
        let dir = URL(filePath: state.sessionDir)
        try Paths.ensure(dir)
        let payload = RunStatePayload(from: state)
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(payload)
        try data.write(to: sidecarURL(for: dir), options: .atomic)
    }

    /// Returns nil if the session name is malformed or the research
    /// root isn't reachable (vault locked, no env override).
    public static func read(_ session: String) -> RunState? {
        guard SessionName.isValid(session),
              let root = researchRoot()
        else { return nil }
        return read(at: sidecarURL(for: root.appending(path: session)))
    }

    /// Read a sidecar at a known path. The session name and dir are
    /// taken from the path itself, not from the JSON, so a renamed
    /// directory is picked up automatically.
    public static func read(at url: URL) -> RunState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let payload = try? decoder.decode(RunStatePayload.self, from: data)
        else { return nil }
        let sessionDir = url.deletingLastPathComponent()
        guard SessionName.isValid(sessionDir.lastPathComponent) else { return nil }
        return RunState(payload: payload, sessionDir: sessionDir)
    }

    /// All sessions found under the research root, sorted by start
    /// time (newest first). Directories without a sidecar are skipped
    /// — they're either vault scratch (`.pi-sessions`) or aborted runs.
    public static func list() -> [RunState] {
        guard let root = researchRoot(),
              let entries = try? FileManager.default.contentsOfDirectory(
                  at: root, includingPropertiesForKeys: [.isDirectoryKey]
              )
        else { return [] }
        return entries
            .compactMap { url -> RunState? in
                guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                else { return nil }
                return read(at: sidecarURL(for: url))
            }
            .sorted { $0.startedAt > $1.startedAt }
    }

    /// Active = status==running and the pid is still alive.
    public static func active() -> [RunState] {
        list().filter { $0.status == .running && pidAlive($0.pid) }
    }

    public static func mostRecent() -> RunState? {
        list().first
    }

    public static func remove(_ session: String) {
        guard SessionName.isValid(session),
              let root = researchRoot()
        else { return }
        try? FileManager.default.removeItem(
            at: sidecarURL(for: root.appending(path: session))
        )
    }

    // MARK: - utilities

    public static func pidAlive(_ pid: Int32) -> Bool {
        // signal 0 = existence check, no signal sent
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// Update an existing sidecar in-place. Lossless for fields the
    /// caller doesn't change.
    public static func update(_ session: String, _ mutate: (inout RunState) -> Void) throws {
        guard var state = read(session) else { return }
        mutate(&state)
        try write(state)
    }

    /// Like `update`, but only fires the mutation if the on-disk status
    /// is still `.running`. Used by the daemon's per-event progress
    /// updates so they can't clobber a `Stop`-written `.stopped` status
    /// in the read-mutate-write window.
    public static func updateIfRunning(
        _ session: String, _ mutate: (inout RunState) -> Void
    ) throws {
        guard var state = read(session), state.status == .running else { return }
        mutate(&state)
        try write(state)
    }
}
