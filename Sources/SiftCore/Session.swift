import Foundation

/// Resolves the session sqlite path the way the Python CLI did:
///   1. ALEPH_DB_PATH override (used by the agent)
///   2. ALEPH_SESSION_DIR / aleph.sqlite (vault mount)
///   3. fall back to ~/.sift/aleph.sqlite for one-shot CLI use
public enum Session {
    public static func dbPath() throws -> URL {
        let env = ProcessInfo.processInfo.environment
        if let override = env["ALEPH_DB_PATH"], !override.isEmpty {
            return URL(filePath: (override as NSString).expandingTildeInPath)
        }
        if let base = env["ALEPH_SESSION_DIR"], !base.isEmpty {
            return URL(filePath: (base as NSString).expandingTildeInPath)
                .appending(path: "aleph.sqlite")
        }
        if let mp = VaultService().findExistingMount() {
            return mp.appending(path: "research").appending(path: "aleph.sqlite")
        }
        return Paths.siftHome.appending(path: "aleph.sqlite")
    }

    public static func openStore() throws -> Store {
        try Store(dbPath: try dbPath())
    }
}
