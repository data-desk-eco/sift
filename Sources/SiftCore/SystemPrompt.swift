import Foundation

/// Build the agent's system prompt: AGENTS.md + SKILL.md + project.md
/// (if set) + an optional deadline note. Written to disk so pi can
/// load it via --system-prompt.
public enum SystemPrompt {
    /// Where the bundled markdown templates live. Set by SiftCLI (the
    /// only target that ships them as resources). Other consumers can
    /// pre-populate this with their own URLs for testing.
    nonisolated(unsafe) public static var resourceFinder: () -> ResourceURLs = {
        ResourceURLs(agentsMD: nil, skillMD: nil)
    }

    public struct ResourceURLs: Sendable {
        public var agentsMD: URL?
        public var skillMD: URL?
        public init(agentsMD: URL?, skillMD: URL?) {
            self.agentsMD = agentsMD
            self.skillMD = skillMD
        }
    }

    public struct DeadlineNote: Sendable {
        /// What the session is for — the deadline is framed differently
        /// for a topic investigation (use the time, go deep) than for the
        /// reconnaissance plan phase (scope it and stop, don't investigate).
        public enum Kind: Sendable { case investigate, plan }
        public let totalMinutes: Int
        public let endLocalTime: String
        public let kind: Kind
        public init(totalMinutes: Int, endLocalTime: String, kind: Kind = .investigate) {
            self.totalMinutes = totalMinutes
            self.endLocalTime = endLocalTime
            self.kind = kind
        }
    }

    public static func build(deadlineNote: DeadlineNote? = nil) throws -> URL {
        let urls = resourceFinder()
        guard let agentsURL = urls.agentsMD,
              let skillURL = urls.skillMD
        else {
            throw SiftError(
                "bundled prompt resources missing",
                suggestion: "package install is broken — try reinstalling sift"
            )
        }

        let agents = (try? String(contentsOf: agentsURL, encoding: .utf8)) ?? ""
        let rawSkill = (try? String(contentsOf: skillURL, encoding: .utf8)) ?? ""
        let skill = stripFrontmatter(rawSkill)

        var parts: [String] = [agents, "\n\n", skill]
        if FileManager.default.fileExists(atPath: Paths.projectFile.path),
           let project = try? String(contentsOf: Paths.projectFile, encoding: .utf8),
           !project.isEmpty {
            parts.append("\n\n## Project context\n\n")
            parts.append(project)
        }
        if let dl = deadlineNote {
            parts.append("\n\n## Deadline\n\n")
            let opening = "This session has a soft deadline of \(dl.totalMinutes) minute(s), "
                + "ending around \(dl.endLocalTime) local time. "
            switch dl.kind {
            case .investigate:
                parts.append(opening
                    + "The budget is a target depth, not a cap to finish under — the "
                    + "user picked it because they want roughly that much investigation. "
                    + "If you find yourself ready to stop with substantial time left, "
                    + "you've almost certainly stopped too early: re-read sources you "
                    + "skimmed, verify findings against fresh searches, broaden the "
                    + "question, or pursue leads you noted but didn't follow. After every "
                    + "few tool calls, run `sift time` to see remaining time and pacing "
                    + "guidance. The deadline itself is soft — there's no hard kill — but "
                    + "write up what you found in your segment before you stop.")
            case .plan:
                parts.append(opening
                    + "It's your window to scope the investigation, not to run it: search "
                    + "broadly to see what the collection holds and queue every angle "
                    + "worth a pass with `sift queue`. It's a budget, not a target to fill "
                    + "— once the worklist covers the brief, stop; don't start "
                    + "investigating the leads yourself or reading deeply. Run `sift time` "
                    + "every few tool calls to check remaining time. The deadline is soft "
                    + "— there's no hard kill — but make sure every lead is queued before "
                    + "you stop.")
            }
        }

        try Paths.ensureSiftHome()
        try parts.joined().write(to: Paths.systemPromptFile, atomically: true, encoding: .utf8)
        return Paths.systemPromptFile
    }

    static func stripFrontmatter(_ text: String) -> String {
        guard text.hasPrefix("---") else { return text }
        let after = text.index(text.startIndex, offsetBy: 3)
        guard let endRange = text.range(of: "\n---", range: after..<text.endIndex) else {
            return text
        }
        var stripped = String(text[endRange.upperBound...])
        while stripped.first?.isNewline == true { stripped.removeFirst() }
        return stripped
    }
}
