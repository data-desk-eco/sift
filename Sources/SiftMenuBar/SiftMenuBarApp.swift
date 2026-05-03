import AppKit
import SiftCore
import SwiftUI

@main
struct SiftMenuBarApp: App {
    @State private var model = RunStateModel()

    init() {
        // No dock icon, no Cmd-Q quit dialog — pure menu bar item.
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContents(model: model)
        } label: {
            Image(systemName: indicatorSymbol)
        }
        .menuBarExtraStyle(.menu)
    }

    /// Templated SF Symbols — rendered in the system's default menu-bar
    /// tint (black/white per appearance), no custom colour.
    private var indicatorSymbol: String {
        switch model.indicator {
        case .running: return "magnifyingglass.circle.fill"
        case .failed:  return "exclamationmark.triangle"
        case .stopped, .idle: return "magnifyingglass"
        }
    }
}

private struct MenuContents: View {
    @Bindable var model: RunStateModel

    var body: some View {
        let recents = model.states.filter {
            $0.status != .running || !RunRegistry.pidAlive($0.pid)
        }

        if model.active.isEmpty, recents.isEmpty {
            Text("No investigations")
        }

        if !model.active.isEmpty {
            Section("Running") {
                ForEach(model.active) { state in
                    Menu(state.session) {
                        Button("Tail log") { model.tailLog(state) }
                        Button("Open folder") { model.openInFinder(state) }
                        Divider()
                        Button("Stop") { model.stop(state) }
                    }
                }
            }
        }

        if !recents.isEmpty {
            Section("Recent") {
                ForEach(recents.prefix(5)) { state in
                    Menu(state.session) {
                        Button("Open report") { model.openReport(state) }
                        Button("Open folder") { model.openInFinder(state) }
                    }
                }
            }
        }

        Divider()
        Button("Open ~/.sift") { NSWorkspace.shared.open(Paths.siftHome) }
        Button("Quit") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}
