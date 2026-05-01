import Foundation

/// Soft deadline for `sift auto` runs. The agent calls `sift time` to
/// see remaining time and pacing guidance; nothing is enforced.
public struct Deadline: Sendable {
    public let startTimestamp: Int
    public let endTimestamp: Int

    public init(startTimestamp: Int, endTimestamp: Int) {
        self.startTimestamp = startTimestamp
        self.endTimestamp = endTimestamp
    }

    public init(seconds: Int, now: Date = Date()) {
        let start = Int(now.timeIntervalSince1970)
        self.startTimestamp = start
        self.endTimestamp = start + seconds
    }

    public var remainingSeconds: Int {
        endTimestamp - Int(Date().timeIntervalSince1970)
    }

    public var totalSeconds: Int {
        max(1, endTimestamp - startTimestamp)
    }

    public var fraction: Double {
        Double(remainingSeconds) / Double(totalSeconds)
    }

    /// Parse strings like `30m`, `1h`, `90s`, `1h30m` into seconds.
    public static func parseDuration(_ raw: String) throws -> Int {
        let cleaned = raw.replacingOccurrences(of: " ", with: "")
        guard !cleaned.isEmpty else {
            throw SiftError("empty duration")
        }
        let pattern = try NSRegularExpression(pattern: #"(\d+)\s*([smhSMH])"#)
        let range = NSRange(cleaned.startIndex..., in: cleaned)
        let matches = pattern.matches(in: cleaned, range: range)
        var consumed = 0
        var total = 0
        for match in matches {
            guard match.range.length == match.range.length else { continue }
            consumed += match.range.length
            guard let nrange = Range(match.range(at: 1), in: cleaned),
                  let urange = Range(match.range(at: 2), in: cleaned),
                  let n = Int(cleaned[nrange])
            else { continue }
            switch cleaned[urange].lowercased() {
            case "s": total += n
            case "m": total += n * 60
            case "h": total += n * 3600
            default:  break
            }
        }
        if total <= 0 || consumed != cleaned.count {
            throw SiftError(
                "can't parse duration '\(raw)'",
                suggestion: "try 30m, 1h, 90s, 1h30m"
            )
        }
        return total
    }

    /// Pacing phase + guidance shown by `sift time`.
    public struct Phase: Sendable {
        public let name: String
        public let guidance: String
    }

    public var phase: Phase {
        let frac = fraction
        if remainingSeconds <= 0 {
            return Phase(
                name: "overrun",
                guidance: "deadline passed — write report.md immediately if you haven't, then stop. Don't open new threads."
            )
        }
        if frac < 0.10 {
            return Phase(
                name: "wrap-up",
                guidance: "write report.md now. Finish the current tool call only; no new searches."
            )
        }
        if frac < 0.25 {
            return Phase(
                name: "consolidate",
                guidance: "stop opening new threads. Tie up loose ends and start drafting report.md."
            )
        }
        if frac < 0.50 {
            return Phase(
                name: "deepen",
                guidance: "no big new directions. Pursue the strongest existing leads to a useful depth."
            )
        }
        return Phase(name: "explore", guidance: "plenty of time. Keep going deep on the question.")
    }

    public static func formatRemaining(_ seconds: Int) -> String {
        let s = max(0, seconds)
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(sec)s" }
        return "\(sec)s"
    }
}
