import ArgumentParser
import Darwin
import Foundation
import SiftCore

struct StopCommand: SiftSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "stop",
        abstract: "Stop the running lead's agent."
    )

    @Argument(help: "lead name (defaults to the running one)")
    var lead: String?

    func execute() async throws {
        let target: RunState
        if let name = lead {
            guard let s = RunRegistry.read(name) else {
                throw SiftError("no such lead: \(name)")
            }
            target = s
        } else {
            let active = RunRegistry.active()
            if active.count == 1 {
                target = active[0]
            } else if active.count > 1 {
                // Prefer the active lead when several runs are live;
                // fall back to demanding an explicit name otherwise.
                if let pinned = ActiveLead.get(),
                   let s = active.first(where: { $0.session == pinned }) {
                    target = s
                } else {
                    let names = active.map { $0.session }.joined(separator: ", ")
                    throw SiftError(
                        "multiple running leads",
                        suggestion: "specify one: \(names)"
                    )
                }
            } else {
                throw SiftError("no running lead")
            }
        }

        if !RunRegistry.pidAlive(target.pid) {
            Log.say("stop", "pid \(target.pid) already gone — marking stopped")
        } else {
            let rc = kill(target.pid, SIGTERM)
            if rc != 0 {
                let err = String(cString: strerror(errno))
                throw SiftError("kill \(target.pid) failed: \(err)")
            }
            Log.say("stop", "SIGTERM → \(target.pid)")
        }
        try? RunRegistry.update(target.session) { st in
            st.status = .stopped
            st.finishedAt = Int(Date().timeIntervalSince1970)
        }
        // Belt-and-braces: the daemon also calls stopLocalIfIdle on
        // exit, but a SIGTERM'd daemon may not run cleanup, so we
        // double up here. Idempotent — no-op if already stopped.
        Backend.stopLocalIfIdle()
    }
}
