import ArgumentParser
import Foundation
import SiftCore

/// `sift render` — read pi's `--mode json` event stream on stdin and print
/// readable `[scope] message` lines to stdout, so a `sift auto` sweep is fun
/// to watch live. Hidden: it's plumbing for `orchestrate.sh`
/// (`pi … --mode json | sift render`), not a command anyone types.
struct RenderCommand: SiftSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "render", shouldDisplay: false
    )

    func execute() async throws {
        var stream = EventStream()
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss'Z'"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "UTC")
        while let line = readLine(strippingNewline: true) {
            for ev in stream.ingest(line) where !ev.formatted.isEmpty {
                // Final assistant prose prints bare so it reads as paragraphs;
                // structured events get a wall-clock prefix for correlation.
                print(ev.isFinalText ? ev.formatted : "\(fmt.string(from: Date())) \(ev.formatted)")
            }
        }
    }
}
