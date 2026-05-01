import ArgumentParser
import Foundation
import SiftCore

struct StatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show running auto-session(s) and recent finishes."
    )
    @Flag(name: [.short, .customLong("all")],
          help: "include finished sessions, not just running ones")
    var all: Bool = false

    func run() async throws {
        let states = RunRegistry.list()
        if states.isEmpty {
            print("(no sift auto sessions on record)")
            return
        }
        let now = Int(Date().timeIntervalSince1970)
        var rows: [[String]] = []
        for state in states {
            let live = state.status == .running && RunRegistry.pidAlive(state.pid)
            if !all, !live, state.status == .running {
                // Stale running entry whose pid is gone.
            } else if !all, !live {
                continue
            }
            let elapsed = formatElapsed(now - state.startedAt)
            let lastEvent = state.lastScope.isEmpty
                ? "(no events)"
                : "\(state.lastScope)  \(state.lastMessage)"
            let status: String
            if live { status = "running" }
            else if state.status == .running { status = "stale" }
            else { status = state.status.rawValue }
            rows.append([
                state.session,
                status,
                elapsed,
                String(state.pid),
                Render.short(lastEvent, width: 60),
            ])
        }
        if rows.isEmpty {
            print("(no running sift auto sessions)")
            return
        }
        print(Table.render(rows, headers: ["session", "status", "age", "pid", "last"]))
    }

    private func formatElapsed(_ s: Int) -> String {
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        if h > 0 { return "\(h)h\(m)m" }
        if m > 0 { return "\(m)m\(sec)s" }
        return "\(sec)s"
    }
}
