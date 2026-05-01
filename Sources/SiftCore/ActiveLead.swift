import Foundation

/// The lead the user is currently focused on. Persists across shells
/// so `sift auto`, `sift logs`, `sift attach`, `sift stop` and `sift
/// time` all default to the same investigation without each invocation
/// having to name it.
///
/// Stored as a single line in `~/.sift/active-lead`. The value is a
/// session directory name (e.g. `abramovich-cyprus-offshore`); this
/// module makes no claim that the named session still exists on disk —
/// the consuming command should validate via `RunRegistry`.
public enum ActiveLead {
    private static var path: URL { Paths.siftHome.appending(path: "active-lead") }

    public static func get() -> String? {
        guard let data = try? Data(contentsOf: path),
              let raw = String(data: data, encoding: .utf8)
        else { return nil }
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    @discardableResult
    public static func set(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
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
