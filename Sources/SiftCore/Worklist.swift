import Foundation

/// The `sift auto` worklist: a plain text file, one topic per line. The
/// file *is* the run state — there's no database, no sidecar. A line is
/// pending unless it's blank, a `#` comment, or already marked done with
/// a leading `✓`. The orchestrator marks each line done as it finishes;
/// the agent appends new topics via `sift queue`, which later sessions
/// pick up. Open the file mid-run and you see exactly what's done,
/// what's queued, and what the agent has surfaced.
public enum Worklist {
    static let doneMarker = "✓ "

    public static func isPending(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return !t.isEmpty && !t.hasPrefix("#") && !t.hasPrefix("✓")
    }

    /// The next un-marked topic (trimmed), or nil when the list is dry.
    public static func next(at path: URL) -> String? {
        guard let text = try? String(contentsOf: path, encoding: .utf8) else { return nil }
        for line in text.components(separatedBy: "\n") where isPending(line) {
            return line.trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// Prefix the first pending line matching `topic` with the done
    /// marker. Re-reads first so topics the agent appended mid-session
    /// survive the rewrite.
    public static func markDone(at path: URL, topic: String) {
        guard let text = try? String(contentsOf: path, encoding: .utf8) else { return }
        var lines = text.components(separatedBy: "\n")
        for i in lines.indices
        where isPending(lines[i]) && lines[i].trimmingCharacters(in: .whitespaces) == topic {
            lines[i] = doneMarker + topic
            break
        }
        try? lines.joined(separator: "\n").write(to: path, atomically: true, encoding: .utf8)
    }

    /// Append a topic for a later session to pick up. No-op on blanks
    /// and exact duplicates of a line already in the file.
    public static func append(at path: URL, topic: String) throws {
        let t = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let existing = (try? String(contentsOf: path, encoding: .utf8)) ?? ""
        let seen = existing.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if seen.contains(t) || seen.contains(doneMarker + t) { return }
        let sep = existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n"
        try (existing + sep + t + "\n").write(to: path, atomically: true, encoding: .utf8)
    }
}
