import Foundation

/// Allow-list validation for session names. Sift always generates
/// kebab-case slugs or `yyyyMMdd-HHmmss` timestamps internally, so
/// every legitimate name fits this pattern. Validation gates every
/// consumer that turns a name into a filesystem path so a corrupted
/// `~/.sift/active-lead`, a typo'd CLI argument, or a malicious tool
/// poking at sift's state can't escape `~/.sift/run/` or the vault's
/// `research/` directory via `..` or `/`.
public enum SessionName {
    /// Throw `SiftError` if `name` isn't a valid session name.
    public static func validate(_ name: String) throws {
        guard !name.isEmpty else {
            throw SiftError("empty session name")
        }
        if name.hasPrefix(".") {
            throw SiftError(
                "invalid session name: \(name)",
                suggestion: "names can't start with '.'"
            )
        }
        if name.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) == nil {
            throw SiftError(
                "invalid session name: \(name)",
                suggestion: "use only letters, digits, '-', '_', '.'"
            )
        }
    }

    public static func isValid(_ name: String) -> Bool {
        (try? validate(name)) != nil
    }
}
