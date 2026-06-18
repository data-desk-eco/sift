import Foundation

/// Resolve the cache sqlite path used by every research command:
///   1. `ALEPH_DB_PATH` override (set by agent harnesses for tests)
///   2. `ALEPH_SESSION_DIR/aleph.sqlite` (the vault-mount path the
///      daemon injects — shared across every session on the vault, so
///      aliases stay stable across investigations)
///   3. `<vault>/research/aleph.sqlite` if the vault is mounted
///   4. `~/.sift/aleph.sqlite` for one-shot CLI use without a vault
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
