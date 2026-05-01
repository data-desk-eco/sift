import AppKit
import Foundation
import Observation
import SiftCore

/// Live view onto the run-state JSON files under `~/.sift/run/`. Driven
/// by a DispatchSource watcher on the directory; falls back to a 2 s
/// poll so we don't drop events during quick rotations. Pure read.
@Observable
final class RunStateModel {
    private(set) var states: [RunState] = []
    private var watcher: DispatchSourceFileSystemObject?
    private var pollTimer: DispatchSourceTimer?

    init() {
        try? Paths.ensure(Paths.runDir)
        reload()
        installWatcher()
        installPoller()
    }

    deinit {
        watcher?.cancel()
        pollTimer?.cancel()
    }

    // MARK: - Derived display state

    var active: [RunState] {
        states.filter { $0.status == .running && RunRegistry.pidAlive($0.pid) }
    }

    var recent: [RunState] {
        let activeIds = Set(active.map { $0.session })
        return states.filter { !activeIds.contains($0.session) }
    }

    /// Symbol shown in the menu bar.
    var indicatorSymbol: String {
        if active.isEmpty { return "magnifyingglass" }
        return "magnifyingglass.circle.fill"
    }

    /// First active session's current scope (e.g. "tool", "agent"),
    /// rendered next to the icon.
    var activeScope: String? {
        active.first?.lastScope.isEmpty == false ? active.first?.lastScope : nil
    }

    // MARK: - Reload

    func reload() {
        let next = RunRegistry.list()
        notifyTransitions(prev: states, next: next)
        states = next
    }

    /// Detect sessions that just transitioned out of `.running` and post
    /// a native notification. We only fire when we've previously seen the
    /// session as running, so finished sessions present at app launch
    /// don't generate stale notifications.
    private func notifyTransitions(prev: [RunState], next: [RunState]) {
        let prevByName = Dictionary(uniqueKeysWithValues: prev.map { ($0.session, $0) })
        for state in next {
            guard let old = prevByName[state.session],
                  old.status == .running, state.status != .running
            else { continue }
            let title: String
            switch state.status {
            case .finished: title = "sift: investigation complete"
            case .failed:   title = "sift: investigation failed"
            case .stopped:  title = "sift: investigation stopped"
            default: continue
            }
            Notifier.shared.post(
                title: title,
                body: "Session \(state.session) — open report.md or run `sift logs`",
                sessionDir: state.sessionDir
            )
        }
    }

    // MARK: - DispatchSource watcher

    private func installWatcher() {
        let fd = open(Paths.runDir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.reload()
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        watcher = source
    }

    private func installPoller() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in self?.reload() }
        timer.resume()
        pollTimer = timer
    }

    // MARK: - Actions

    func stop(_ state: RunState) {
        guard RunRegistry.pidAlive(state.pid) else { return }
        kill(state.pid, SIGTERM)
        try? RunRegistry.update(state.session) { st in
            st.status = .stopped
            st.finishedAt = Int(Date().timeIntervalSince1970)
        }
        reload()
    }

    func openInFinder(_ state: RunState) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: state.sessionDir)])
    }

    func openReport(_ state: RunState) {
        let report = URL(filePath: state.sessionDir).appending(path: "report.md")
        if FileManager.default.fileExists(atPath: report.path) {
            NSWorkspace.shared.open(report)
        } else {
            openInFinder(state)
        }
    }

    /// Open Terminal.app and run `sift logs -f <session>`. Uses
    /// osascript because there's no AppKit API for "open terminal with
    /// command" without breaking on Terminal-vs-iTerm divergence.
    func tailLog(_ state: RunState) {
        let command = "sift logs -f \(shellQuote(state.session))"
        let script = """
            tell application "Terminal"
                activate
                do script "\(escapedAppleScript(command))"
            end tell
            """
        let proc = Process()
        proc.executableURL = URL(filePath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        try? proc.run()
    }

    private func shellQuote(_ s: String) -> String {
        if s.range(of: #"^[A-Za-z0-9_./-]+$"#, options: .regularExpression) != nil { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func escapedAppleScript(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

// MARK: - Equatable for RunState (for SwiftUI ForEach diffing)

extension RunState: Identifiable {
    public var id: String { session }
}

extension RunState: Equatable {
    public static func == (lhs: RunState, rhs: RunState) -> Bool {
        lhs.session == rhs.session
            && lhs.status == rhs.status
            && lhs.lastEventAt == rhs.lastEventAt
    }
}
