import Foundation

/// Allow-list validation for session names (and a small helper to
/// derive a default kebab slug from a free-text prompt). Sift always
/// generates kebab-case slugs or `yyyyMMdd-HHmmss` timestamps
/// internally, so every legitimate name fits the validation pattern.
/// Validation gates every consumer that turns a name into a filesystem
/// path so a corrupted `~/.sift/active-lead`, a typo'd CLI argument,
/// or a malicious tool poking at sift's state can't escape `~/.sift/run/`
/// or the vault's `research/` directory via `..` or `/`.
public enum SessionName {
    /// Throw `SiftError` if `name` isn't a valid session name.
    public static func validate(_ name: String) throws {
        guard !name.isEmpty else {
            throw SiftError("empty lead name")
        }
        if name.hasPrefix(".") {
            throw SiftError(
                "invalid lead name: \(name)",
                suggestion: "names can't start with '.'"
            )
        }
        if name.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) == nil {
            throw SiftError(
                "invalid lead name: \(name)",
                suggestion: "use only letters, digits, '-', '_', '.'"
            )
        }
    }

    public static func isValid(_ name: String) -> Bool {
        (try? validate(name)) != nil
    }

    /// Default lead slug derived from the first ~40 chars of a prompt.
    /// Lowercased, alphanumerics-and-single-hyphens only. Returns an
    /// empty string for prompts with no usable characters; callers
    /// should fall back to a timestamp in that case.
    public static func suggest(from prompt: String) -> String {
        kebabify(prompt, maxLength: 40)
    }

    /// Lowercase, alpha-numerics with single-hyphen separators; runs of
    /// other characters collapse to one `-`. Truncated to `maxLength`,
    /// then leading/trailing hyphens stripped — order matters: a
    /// 40-char prefix that lands mid-word would otherwise leave a
    /// trailing `-`.
    static func kebabify(_ raw: String, maxLength: Int) -> String {
        var slug = ""
        for ch in raw.lowercased() {
            if ch.isLetter || ch.isNumber {
                slug.append(ch)
            } else if !slug.isEmpty, slug.last != "-" {
                slug.append("-")
            }
        }
        slug = String(slug.prefix(maxLength))
        while slug.hasSuffix("-") { slug.removeLast() }
        while slug.hasPrefix("-") { slug.removeFirst() }
        return slug
    }
}
