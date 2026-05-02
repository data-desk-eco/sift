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
            PopoverView(model: model)
        } label: {
            IndicatorDot(state: model.indicator)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Status circle in the menu bar. Filled in colour when something is
/// running or the last run failed; hollow stroke when idle. No text —
/// `sift status` / the popover carry the detail.
private struct IndicatorDot: View {
    let state: RunStateModel.Indicator

    var body: some View {
        switch state {
        case .running:
            Circle().fill(.blue).frame(width: 10, height: 10)
        case .failed:
            Circle().fill(.red).frame(width: 10, height: 10)
        case .stopped:
            Circle().fill(.orange).frame(width: 10, height: 10)
        case .idle:
            Circle()
                .strokeBorder(.secondary, lineWidth: 1.25)
                .frame(width: 10, height: 10)
        }
    }
}
