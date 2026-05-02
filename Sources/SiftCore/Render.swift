import Foundation

/// Output shaping for command results. Same `[header]\n────\nbody`
/// envelope humans and the agent both consume — keeping it identical
/// matters more than making it pretty.
public enum Render {
    public static let rule = String(repeating: "\u{2500}", count: 60)
    public static let defaultBodyChars = 1500
    public static let defaultTitleWidth = 60

    public static func envelope(
        _ header: String,
        _ body: String,
        cached: Bool = false
    ) -> String {
        let tag = cached ? "  (cached)" : ""
        return "[\(header)]\(tag)\n\(rule)\n\(body.trimmingTrailingWhitespace())"
    }

    public static func truncate(_ text: String, maxChars: Int = defaultBodyChars) -> String {
        guard !text.isEmpty else { return "" }
        guard text.count > maxChars else { return text }
        let head = String(text.prefix(maxChars)).trimmingTrailingWhitespace()
        let dropped = text.count - maxChars
        return "\(head)\n[…+\(dropped) chars truncated, pass --full]"
    }

    public static func short(_ text: String?, width: Int = defaultTitleWidth) -> String {
        guard let text, !text.isEmpty else { return "" }
        let clean = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard clean.count > width else { return clean }
        return String(clean.prefix(width - 1)) + "\u{2026}"
    }

    // MARK: - FtM property coercion helpers

    /// Aleph property values come in three shapes: scalar string, dict
    /// with `label`/`name`/`id`, or array of either. Squash to a string.
    public static func extractLabel(_ value: Any?) -> String {
        switch value {
        case nil, is NSNull:
            return ""
        case let dict as [String: Any]:
            for k in ["label", "name", "id"] {
                if let v = dict[k] as? String, !v.isEmpty { return v }
                if let v = dict[k] { return "\(v)" }
            }
            return ""
        case let arr as [Any]:
            return arr.map { extractLabel($0) }
                .filter { !$0.isEmpty }
                .joined(separator: ", ")
        case let s as String:
            return s
        case let v?:
            return "\(v)"
        }
    }

    public static func firstLabel(_ value: Any?) -> String {
        if let arr = value as? [Any] {
            return arr.isEmpty ? "" : extractLabel(arr[0])
        }
        return extractLabel(value)
    }

    public static func firstString(_ value: Any?) -> String? {
        if let s = value as? String, !s.isEmpty { return s }
        if let arr = value as? [Any], let first = arr.first as? String, !first.isEmpty {
            return first
        }
        return nil
    }

    private static let subjectPrefixRe = try! NSRegularExpression(
        pattern: #"^(?:\s*(?:re|fwd?|aw|sv|tr|antw|wg)\s*:\s*)+"#,
        options: .caseInsensitive
    )

    public static func normalizeSubject(_ subject: String?) -> String {
        guard let subject, !subject.isEmpty else { return "" }
        let range = NSRange(subject.startIndex..., in: subject)
        let stripped = subjectPrefixRe.stringByReplacingMatches(
            in: subject, range: range, withTemplate: ""
        )
        return stripped
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
    }

    private static let emailNameRe = try! NSRegularExpression(
        pattern: #"^\s*(.+?)\s*<[^>]+>\s*$"#
    )

    public static func stripEmailAddress(_ sender: String) -> String {
        guard !sender.isEmpty else { return "" }
        let range = NSRange(sender.startIndex..., in: sender)
        if let match = emailNameRe.firstMatch(in: sender, range: range),
           let r = Range(match.range(at: 1), in: sender) {
            return String(sender[r])
        }
        return sender
    }

    /// Walk a possibly-nested entity reference (string id, `{id: ...}`,
    /// or array thereof) and return the first id encountered.
    public static func firstEntityRefId(_ value: Any?) -> String? {
        switch value {
        case let s as String where !s.isEmpty:
            return s
        case let dict as [String: Any]:
            if let i = dict["id"] as? String, !i.isEmpty { return i }
            return nil
        case let arr as [Any]:
            for item in arr {
                if let r = firstEntityRefId(item) { return r }
            }
            return nil
        default:
            return nil
        }
    }

    /// Collect every `id` string referenced inside a property value.
    public static func referencedIdStrings(_ value: Any?) -> [String] {
        var out: [String] = []
        func walk(_ v: Any?) {
            switch v {
            case let s as String where !s.isEmpty:
                out.append(s)
            case let dict as [String: Any]:
                if let i = dict["id"] as? String, !i.isEmpty { out.append(i) }
            case let arr as [Any]:
                for x in arr { walk(x) }
            default: break
            }
        }
        walk(value)
        return out
    }
}

// MARK: - Table renderer

/// Borderless `simple` table — column-aligned, header underlined with
/// dashes, no other rules.
public enum Table {
    public static func render(_ rows: [[String]], headers: [String]) -> String {
        guard !headers.isEmpty else { return "" }
        let cols = headers.count
        var widths = headers.map { $0.displayWidth }
        for row in rows {
            for i in 0..<cols where i < row.count {
                widths[i] = max(widths[i], row[i].displayWidth)
            }
        }

        func format(_ cells: [String]) -> String {
            var parts: [String] = []
            for i in 0..<cols {
                let cell = i < cells.count ? cells[i] : ""
                parts.append(cell.paddedDisplay(to: widths[i]))
            }
            return parts.joined(separator: "  ").trimmingTrailingWhitespace()
        }

        var lines: [String] = []
        lines.append(format(headers))
        lines.append(format(widths.map { String(repeating: "-", count: $0) }))
        for row in rows {
            lines.append(format(row.map { $0 }))
        }
        return lines.joined(separator: "\n")
    }
}

extension String {
    func trimmingTrailingWhitespace() -> String {
        var s = self
        while let last = s.last, last.isWhitespace { s.removeLast() }
        return s
    }

    /// Visual width approximation: counts grapheme clusters. Good
    /// enough for ASCII-heavy table output; no East Asian width handling.
    var displayWidth: Int { count }

    func paddedDisplay(to width: Int) -> String {
        let extra = width - displayWidth
        return extra > 0 ? self + String(repeating: " ", count: extra) : self
    }
}
