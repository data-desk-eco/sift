import ArgumentParser
import Foundation
import SiftCore

/// Append a paragraph to the current topic's segment. Agent-facing — the
/// model calls this the moment a document establishes something, instead
/// of hand-editing the segment file with pi's generic file tool (a
/// read-modify-write the weak local model fumbles or batches to the end,
/// leaving topics with no segment at all). One call, append-only, creates
/// the file on first use. Only meaningful inside a `sift auto` run, which
/// sets `$SIFT_SEGMENT` to the segment path.
struct NoteCommand: SiftSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "note",
        abstract: "Append a finding to this topic's segment of the report."
    )

    @Argument(help: "the finding, in neutral prose, citing source aliases inline")
    var text: [String] = []

    func execute() async throws {
        guard let path = ProcessInfo.processInfo.environment["SIFT_SEGMENT"],
              !path.isEmpty else {
            throw SiftError(
                "no active segment",
                suggestion: "`sift note` only works inside a `sift auto` run"
            )
        }
        let body = text.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else {
            throw SiftError("nothing to note", suggestion: "`sift note \"<finding>\"`")
        }
        let url = URL(filePath: path)
        // Append as its own block (blank line between) so the segment reads
        // as separate paragraphs/sections rather than one run-on line.
        let prior = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let sep = prior.isEmpty ? "" : (prior.hasSuffix("\n\n") ? "" : prior.hasSuffix("\n") ? "\n" : "\n\n")
        try (prior + sep + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        let size = ((try? String(contentsOf: url, encoding: .utf8))?.count ?? 0)
        Log.say("note", "appended (\(size) chars in segment)")
    }
}
