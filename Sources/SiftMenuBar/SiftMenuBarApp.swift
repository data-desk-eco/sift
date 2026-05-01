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
            HStack(spacing: 4) {
                Image(systemName: model.indicatorSymbol)
                if let scope = model.activeScope {
                    Text(scope).font(.system(size: 11)).monospaced()
                }
            }
        }
        .menuBarExtraStyle(.window)
    }
}
