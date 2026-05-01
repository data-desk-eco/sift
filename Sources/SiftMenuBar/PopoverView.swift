import AppKit
import SiftCore
import SwiftUI

struct PopoverView: View {
    @Bindable var model: RunStateModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if model.active.isEmpty, model.states.isEmpty {
                empty
            } else {
                if !model.active.isEmpty {
                    sectionTitle("running")
                    ForEach(model.active) { state in
                        ActiveRow(state: state, model: model)
                    }
                }
                if !model.states.filter({ $0.status != .running || !RunRegistry.pidAlive($0.pid) }).isEmpty {
                    Divider().padding(.vertical, 4)
                    sectionTitle("recent")
                    ForEach(model.states.filter { state in
                        state.status != .running || !RunRegistry.pidAlive(state.pid)
                    }.prefix(5)) { state in
                        RecentRow(state: state, model: model)
                    }
                }
            }

            Divider().padding(.vertical, 4)
            footer
        }
        .padding(12)
        .frame(width: 360)
    }

    private var header: some View {
        HStack {
            Image(systemName: "magnifyingglass.circle")
                .font(.title2)
            Text("sift").font(.headline)
            Spacer()
            if !model.active.isEmpty {
                Text("\(model.active.count) running")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.bottom, 8)
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("no investigations yet")
                .foregroundStyle(.secondary)
            Text("run `sift auto \"…\"` from a terminal to start one.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 8)
    }

    private func sectionTitle(_ s: String) -> some View {
        Text(s)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.bottom, 4)
    }

    private var footer: some View {
        HStack {
            Button("open ~/.sift") {
                NSWorkspace.shared.open(Paths.siftHome)
            }
            .buttonStyle(.borderless)
            .font(.caption)
            Spacer()
            Button("quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless)
                .font(.caption)
                .keyboardShortcut("q")
        }
    }
}

private struct ActiveRow: View {
    let state: RunState
    let model: RunStateModel
    @State private var now = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Image(systemName: "circle.fill")
                    .foregroundStyle(.green)
                    .font(.system(size: 8))
                Text(state.session)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(elapsed)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text(scopeLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
            }
            HStack(spacing: 6) {
                Spacer()
                Button("tail") { model.tailLog(state) }
                    .buttonStyle(.borderless).font(.caption)
                Button("folder") { model.openInFinder(state) }
                    .buttonStyle(.borderless).font(.caption)
                Button("stop") { model.stop(state) }
                    .buttonStyle(.borderless).font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 6)
        .onReceive(tick) { now = $0 }
    }

    private var elapsed: String {
        let secs = max(0, Int(now.timeIntervalSince1970) - state.startedAt)
        let h = secs / 3600, m = (secs % 3600) / 60, s = secs % 60
        if h > 0 { return "\(h)h\(m)m" }
        if m > 0 { return "\(m)m\(s)s" }
        return "\(s)s"
    }

    private var scopeLabel: String {
        if state.lastScope.isEmpty { return "starting…" }
        return "[\(state.lastScope)] \(state.lastMessage)"
    }
}

private struct RecentRow: View {
    let state: RunState
    let model: RunStateModel

    var body: some View {
        HStack {
            Image(systemName: statusSymbol)
                .foregroundStyle(statusColor)
                .font(.system(size: 10))
            Text(state.session)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button("report") { model.openReport(state) }
                .buttonStyle(.borderless).font(.caption)
            Button("folder") { model.openInFinder(state) }
                .buttonStyle(.borderless).font(.caption)
        }
        .padding(.vertical, 4)
    }

    private var statusSymbol: String {
        switch state.status {
        case .finished: return "checkmark.circle.fill"
        case .failed:   return "xmark.octagon.fill"
        case .stopped:  return "stop.circle.fill"
        case .running:  return "exclamationmark.triangle.fill"  // stale running
        }
    }
    private var statusColor: Color {
        switch state.status {
        case .finished: return .green
        case .failed:   return .red
        case .stopped:  return .gray
        case .running:  return .orange
        }
    }
}
