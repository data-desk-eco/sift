import Foundation

/// Persisted state for a running (or recently finished) `sift auto`
/// daemon. One JSON file per session under `~/.sift/run/`. The CLI's
/// `sift status` / `sift logs` / `sift stop` read from here, and the
/// menu bar app watches the directory via DispatchSource for live
/// updates without polling.
public struct RunState: Codable, Sendable {
    public enum Status: String, Codable, Sendable {
        case running, finished, failed, stopped
    }

    public var session: String
    public var sessionDir: String
    public var logPath: String
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
}

public enum RunRegistry {
    public static func filePath(for session: String) -> URL {
        Paths.runDir.appending(path: "\(session).json")
    }

    public static func write(_ state: RunState) throws {
        try Paths.ensure(Paths.runDir)
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        try data.write(to: filePath(for: state.session), options: .atomic)
    }

    public static func read(_ session: String) -> RunState? {
        read(at: filePath(for: session))
    }

    public static func read(at url: URL) -> RunState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(RunState.self, from: data)
    }

    /// All run-state files, sorted by start time (newest first).
    public static func list() -> [RunState] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: Paths.runDir, includingPropertiesForKeys: nil
        ) else { return [] }
        return entries
            .filter { $0.pathExtension == "json" }
            .compactMap { read(at: $0) }
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
        try? FileManager.default.removeItem(at: filePath(for: session))
    }

    // MARK: - utilities

    public static func pidAlive(_ pid: Int32) -> Bool {
        // signal 0 = existence check, no signal sent
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// Update an existing run state file in-place. Lossless for fields
    /// the caller doesn't change.
    public static func update(_ session: String, _ mutate: (inout RunState) -> Void) throws {
        guard var state = read(session) else { return }
        mutate(&state)
        try write(state)
    }
}
