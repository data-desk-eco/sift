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

    /// Every pending topic, in file order.
    public static func pending(at path: URL) -> [String] {
        guard let text = try? String(contentsOf: path, encoding: .utf8) else { return [] }
        return text.components(separatedBy: "\n").filter(isPending)
            .map { $0.trimmingCharacters(in: .whitespaces) }
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

    /// Hidden, append-only sibling of the visible worklist that records
    /// every queued lead. The agent is never told about it, so a stray
    /// generic-file write that clobbers topics.txt — which is exactly how
    /// a planning run once lost 13 of 16 queued leads — can't touch the
    /// canonical list. `rebuildFromLedger` restores topics.txt from it.
    static func ledger(for path: URL) -> URL {
        path.deletingLastPathComponent().appending(path: ".leads")
    }

    /// Overwrite `path` with every distinct lead from the ledger, all
    /// pending. Run once after a *fresh* plan to undo any direct write
    /// the planner made to the visible worklist; never on resume, where
    /// topics.txt holds real sweep progress the ledger doesn't track.
    public static func rebuildFromLedger(at path: URL) {
        guard let text = try? String(contentsOf: ledger(for: path), encoding: .utf8) else { return }
        var seen = Set<String>(), leads: [String] = []
        for line in text.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || seen.contains(t) { continue }
            seen.insert(t); leads.append(t)
        }
        guard !leads.isEmpty else { return }
        try? (leads.joined(separator: "\n") + "\n").write(to: path, atomically: true, encoding: .utf8)
    }

    /// Append a topic for a later session to pick up. No-op on blanks
    /// and exact duplicates. Records to the hidden ledger first (raw —
    /// rebuild dedups on read) so the lead survives even if a stray write
    /// later clobbers the visible file.
    public static func append(at path: URL, topic: String) throws {
        let t = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let led = ledger(for: path)
        let prior = (try? String(contentsOf: led, encoding: .utf8)) ?? ""
        try? (prior + t + "\n").write(to: led, atomically: true, encoding: .utf8)
        let existing = (try? String(contentsOf: path, encoding: .utf8)) ?? ""
        let seen = existing.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if seen.contains(t) || seen.contains(doneMarker + t) { return }
        let sep = existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n"
        try (existing + sep + t + "\n").write(to: path, atomically: true, encoding: .utf8)
    }
}
