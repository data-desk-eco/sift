import ArgumentParser
import Foundation
import SiftCore

struct StatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show running and recently-finished leads."
    )

    @Flag(name: [.short, .customLong("all")],
          help: "include every lead on record, not just the most recent finishes")
    var all: Bool = false

    private static let recentLimit = 10

    func run() async throws {
        let states = RunRegistry.list()
        if states.isEmpty {
            print("(no leads on record)")
            return
        }

        let now = Int(Date().timeIntervalSince1970)
        let visible = all ? states : trimToRecent(states, limit: Self.recentLimit)
        let lead = ActiveLead.get()

        var rows: [[String]] = []
        for state in visible {
            let live = state.status == .running && RunRegistry.pidAlive(state.pid)
            let status: String
            if live { status = "running" }
            else if state.status == .running { status = "stale" }
            else { status = state.status.rawValue }

            let ageRef = (state.status == .running) ? state.startedAt : (state.finishedAt ?? state.startedAt)
            let age = formatElapsed(now - ageRef)

            let lastEvent = state.lastScope.isEmpty
                ? "(no events)"
                : "\(state.lastScope)  \(state.lastMessage)"

            // Asterisk in the leftmost column marks the active lead, so
            // `sift status` doubles as "which one will `sift auto`
            // resume by default".
            let marker = (state.session == lead) ? "*" : " "

            rows.append([
                marker,
                state.session,
                status,
                age,
                String(state.pid),
                Render.short(lastEvent, width: 60),
            ])
        }
        print(Table.render(rows, headers: [" ", "lead", "status", "age", "pid", "last"]))
    }

    /// All currently-running sessions, plus up to `limit` most recent
    /// terminal ones. `RunRegistry.list()` already returns rows sorted
    /// by `startedAt` descending.
    private func trimToRecent(_ states: [RunState], limit: Int) -> [RunState] {
        let running = states.filter { $0.status == .running }
        let terminal = states.filter { $0.status != .running }.prefix(limit)
        return running + terminal
    }

    private func formatElapsed(_ s: Int) -> String {
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        if h > 0 { return "\(h)h\(m)m" }
        if m > 0 { return "\(m)m\(sec)s" }
        return "\(sec)s"
    }
}
