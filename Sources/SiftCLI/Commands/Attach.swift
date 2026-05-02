import ArgumentParser
import Foundation
import SiftCore

/// "Attach" is a soft concept here — the daemon detaches from any TTY
/// when it spawns, so we can't truly hand over stdin/stdout. What we
/// can do is open a follow-tail of the live log, which is what users
/// usually want anyway.
struct AttachCommand: SiftSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "attach",
        abstract: "Tail the running auto-session log (alias for `sift logs -f`)."
    )

    @Argument(help: "session name (defaults to the running one)")
    var session: String?

    func execute() async throws {
        let target: RunState
        if let name = session {
            guard let s = RunRegistry.read(name) else {
                throw SiftError("no such session: \(name)")
            }
            target = s
        } else if let active = RunRegistry.active().first {
            target = active
        } else if let lead = ActiveLead.get(), let s = RunRegistry.read(lead) {
            Log.say("attach", "no running session — showing active lead (\(s.session))")
            target = s
        } else if let recent = RunRegistry.mostRecent() {
            Log.say("attach", "no running session — showing most recent (\(recent.session))")
            target = recent
        } else {
            throw SiftError("no sift auto sessions on record")
        }
        var logs = LogsCommand()
        logs.session = target.session
        logs.follow = true
        try await logs.execute()
    }
}
