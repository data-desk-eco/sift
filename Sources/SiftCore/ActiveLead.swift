import Foundation

/// The lead the user is currently focused on. Persists across shells
/// so `sift auto`, `sift logs`, `sift attach`, `sift stop` and `sift
/// time` all default to the same investigation without each invocation
/// having to name it.
///
/// Stored as a single line in `~/.sift/active-lead`. The value is a
/// session directory name (e.g. `abramovich-cyprus-offshore`); when
/// the research root is reachable, `get()` validates that the named
/// directory still exists on disk and returns nil otherwise — so a
/// renamed or deleted session falls through to "most recent" instead
/// of resurrecting an empty session under the stale name.
public enum ActiveLead {
    private static var path: URL { Paths.siftHome.appending(path: "active-lead") }

    public static func get() -> String? {
        guard let data = try? Data(contentsOf: path),
              let raw = String(data: data, encoding: .utf8)
        else { return nil }
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Treat a corrupted lead file (someone wrote junk, or a name
        // with `..` / `/`) as "no lead" rather than letting it become
        // a filesystem path component downstream.
        guard SessionName.isValid(name) else { return nil }
        // Validate against the research root when it's reachable —
        // a missing dir means the user renamed or deleted the session
        // after pinning. When the root isn't reachable (vault locked,
        // no env override), trust the recorded name; the caller will
        // hit a normal "no such lead" error downstream.
        if let root = RunRegistry.researchRoot() {
            let dir = root.appending(path: name)
            guard FileManager.default.fileExists(atPath: dir.path) else { return nil }
        }
        return name
    }

    @discardableResult
    public static func set(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard SessionName.isValid(trimmed) else { return false }
        try? Paths.ensure(Paths.siftHome)
        do {
            try (trimmed + "\n").data(using: .utf8)?.write(to: path, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    public static func clear() -> Bool {
        if !FileManager.default.fileExists(atPath: path.path) { return true }
        return (try? FileManager.default.removeItem(at: path)) != nil
    }
}
