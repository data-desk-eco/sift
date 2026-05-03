import AppKit
import Foundation
import Observation
import SiftCore

/// Live view onto the per-session sidecars under
/// `<vault>/research/*/.sift-run.json`. Driven by a DispatchSource
/// watcher on the research root (re-installed when a vault becomes
/// available); falls back to a 2 s poll so we don't drop events
/// during quick rotations or when no vault is mounted yet. Pure read.
@Observable
final class RunStateModel {
    private(set) var states: [RunState] = []
    private var watcher: DispatchSourceFileSystemObject?
    private var watchedPath: String?
    private var pollTimer: DispatchSourceTimer?

    init() {
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

    /// Coarse-grained state for the menu bar dot. Drives a fill colour
    /// rather than a symbol — the bar shouldn't shout at the user, it
    /// should give them an at-a-glance read of "anything running?" and
    /// "did the last thing blow up?".
    enum Indicator {
        case idle      // no runs, or last terminal finished cleanly
        case running   // at least one live agent
        case stopped   // most recent terminal was user-stopped
        case failed    // most recent terminal was an error exit
    }

    var indicator: Indicator {
        if !active.isEmpty { return .running }
        // Find the most recent terminal run (sorted desc by startedAt).
        for state in states where state.status != .running {
            switch state.status {
            case .failed:   return .failed
            case .stopped:  return .stopped
            case .finished: return .idle
            case .running:  continue
            }
        }
        return .idle
    }

    // MARK: - Reload

    func reload() {
        let next = RunRegistry.list()
        notifyTransitions(prev: states, next: next)
        states = next
        // The research dir only becomes reachable after the user
        // unlocks the vault. Re-install the directory watcher whenever
        // its target path changes (vault mounted / unmounted / swapped).
        let target = RunRegistry.researchRoot()?.path
        if target != watchedPath {
            installWatcher()
        }
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
        watcher?.cancel()
        watcher = nil
        watchedPath = nil
        guard let root = RunRegistry.researchRoot() else { return }
        let fd = open(root.path, O_EVTONLY)
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
        watchedPath = root.path
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
        // Free llama-server's ~14 GB if no other auto run still needs
        // it — same logic as the CLI `sift stop`.
        Backend.stopLocalIfIdle()
        reload()
    }

    func openInFinder(_ state: RunState) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: state.sessionDir)])
    }

    /// Render the lead's report.md as HTML (with alias→Aleph entity
    /// links) via the bundled sift CLI, then let the CLI open it in the
    /// browser. Runs on a background queue because rendering touches
    /// SQLite. Falls back to opening the raw markdown if the render
    /// fails — most commonly because the vault is locked or no Aleph
    /// URL is stored.
    func openReport(_ state: RunState) {
        let siftPath = Paths.findExecutable("sift")
            ?? ProcessInfo.processInfo.environment["HOME"].map { "\($0)/.local/bin/sift" }
        guard let siftPath, FileManager.default.isExecutableFile(atPath: siftPath) else {
            openMarkdownFallback(state)
            return
        }
        Task.detached {
            let result = try? Subprocess.run(
                [siftPath, "report", "--format", "html"],
                cwd: URL(filePath: state.sessionDir)
            )
            if result?.code != 0 {
                await self.reportRenderFailed(state, stderr: result?.stderr ?? "")
            }
        }
    }

    @MainActor
    private func reportRenderFailed(_ state: RunState, stderr: String) {
        Notifier.shared.post(
            title: "sift: HTML render failed",
            body: stderr.isEmpty
                ? "Opened report.md instead — see `sift logs` for details."
                : stderr,
            sessionDir: state.sessionDir
        )
        openMarkdownFallback(state)
    }

    private func openMarkdownFallback(_ state: RunState) {
        let report = URL(filePath: state.sessionDir).appending(path: "report.md")
        if FileManager.default.fileExists(atPath: report.path) {
            NSWorkspace.shared.open(report)
        } else {
            openInFinder(state)
        }
    }

    /// Open the user's default terminal and run `sift logs -f <session>`.
    /// We write a `.command` file and let Launch Services dispatch it —
    /// macOS opens `.command` files in whatever the user has set as the
    /// default app (Terminal.app out of the box, but Ghostty / iTerm /
    /// Wezterm if the user has changed it via Finder → Get Info →
    /// Open With → Change All).
    func tailLog(_ state: RunState) {
        let siftPath = ProcessInfo.processInfo.environment["HOME"]
            .map { "\($0)/.local/bin/sift" } ?? "sift"
        let script = """
            #!/bin/zsh -l
            exec \(Sift.shellQuote(siftPath)) logs -f \(Sift.shellQuote(state.session))
            """
        // Stable per-session path so repeated clicks reuse one file
        // instead of leaving a fresh tmp turd in /tmp every time.
        let dir = Paths.siftHome.appending(path: "tail")
        try? Paths.ensure(dir)
        let url = dir.appending(path: "\(state.session).command")
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: url.path
            )
            NSWorkspace.shared.open(url)
        } catch {
            // Fallback: open in Finder so the user can investigate.
            openInFinder(state)
        }
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
