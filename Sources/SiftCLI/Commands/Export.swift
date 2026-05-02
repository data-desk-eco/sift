import AppKit
import ArgumentParser
import Foundation
import SiftCore

struct ExportCommand: SiftSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Render report.md → report.html with alias→Aleph entity links.",
        discussion: """
            With no SRC, exports the current session's report.md (cwd if it
            has one, else the most recently modified session under the
            vault). With --share, opens the macOS share sheet for the
            generated HTML instead of opening it in the browser.
            """
    )

    @Argument(help: "path to report.md (defaults to current session)")
    var src: String?

    @Option(name: [.short, .customLong("out")],
            help: "output file (default: SRC with .html extension)")
    var out: String?

    @Option(help: "Aleph base URL for entity links (default: stored ALEPH_URL)")
    var server: String?

    @Flag(name: .customLong("no-open"),
          help: "don't pop the rendered HTML in the default browser")
    var noOpen: Bool = false

    @Flag(help: "show a macOS share sheet instead of opening in browser")
    var share: Bool = false

    func execute() async throws {
        let srcURL = try resolveSource()
        let dstURL: URL
        if let outPath = out {
            dstURL = URL(filePath: (outPath as NSString).expandingTildeInPath)
        } else {
            dstURL = srcURL.deletingPathExtension().appendingPathExtension("html")
        }

        let serverURL: String
        if let s = server, !s.isEmpty {
            serverURL = s
        } else if let s = Keychain.get(Keychain.Key.alephURL), !s.isEmpty {
            serverURL = s
        } else {
            throw SiftError(
                "no Aleph server URL — can't build entity links",
                suggestion: "pass --server https://aleph.example.org or store with 'sift vault set ALEPH_URL ...'"
            )
        }

        let store = try openSessionStore()
        let counts = try Report.export(
            src: srcURL, dst: dstURL,
            store: store, defaultServer: serverURL
        )

        var msg = "[export]   \(srcURL.path) → \(dstURL.path)  (\(counts.linked) aliases linked"
        if counts.unresolved > 0 { msg += ", \(counts.unresolved) unresolved" }
        msg += ")"
        print(msg)

        // Set Spotlight metadata so the report is searchable from Finder.
        applySpotlight(to: dstURL, src: srcURL)

        if share {
            showShareSheet(for: dstURL)
        } else if !noOpen {
            NSWorkspace.shared.open(dstURL)
        }
    }

    private func resolveSource() throws -> URL {
        if let s = src {
            let url = URL(filePath: (s as NSString).expandingTildeInPath)
            if !FileManager.default.fileExists(atPath: url.path) {
                throw SiftError("no such file: \(url.path)")
            }
            return url
        }
        let cwd = FileManager.default.currentDirectoryPath
        let cwdReport = URL(filePath: cwd).appending(path: "report.md")
        if FileManager.default.fileExists(atPath: cwdReport.path) {
            return cwdReport
        }
        // Fall back to most-recent session under the vault.
        let env = ProcessInfo.processInfo.environment
        var base: URL?
        if let dir = env["ALEPH_SESSION_DIR"] {
            base = URL(filePath: dir)
        } else if let mp = VaultService().findExistingMount() {
            base = mp.appending(path: "research")
        }
        guard let baseURL = base else {
            throw SiftError(
                "no report.md in cwd and no session dir to search",
                suggestion: "cd into a session dir, pass an explicit path, or unlock the vault"
            )
        }
        let candidates = (try? FileManager.default.contentsOfDirectory(
            at: baseURL, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        let reports = candidates.compactMap { url -> URL? in
            let rep = url.appending(path: "report.md")
            return FileManager.default.fileExists(atPath: rep.path) ? rep : nil
        }
        guard let latest = reports.max(by: { mtime($0) < mtime($1) }) else {
            throw SiftError(
                "no report.md found under \(baseURL.path)",
                suggestion: "run `sift auto \"...\"` to create one, or pass an explicit path"
            )
        }
        return latest
    }

    private func mtime(_ url: URL) -> TimeInterval {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return ((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970) ?? 0
    }

    private func applySpotlight(to dst: URL, src: URL) {
        // Tag the HTML so `mdfind 'kMDItemKeywords == "sift-report"'` works.
        let attrs: [String: Any] = [
            "kMDItemKeywords": ["sift-report", "investigation"],
            "kMDItemDescription": "sift investigation report rendered from \(src.lastPathComponent)",
        ]
        for (key, value) in attrs {
            let raw: String
            if let arr = value as? [String] {
                raw = "(" + arr.map { "\"\($0)\"" }.joined(separator: ", ") + ")"
            } else {
                raw = "\"\(value)\""
            }
            _ = try? Subprocess.run([
                "/usr/bin/xattr", "-w",
                "com.apple.metadata:\(key)", raw, dst.path,
            ])
        }
    }

    private func showShareSheet(for url: URL) {
        // NSSharingServicePicker needs a window. Without one, fall back to
        // copying the HTML path to the clipboard and opening Finder.
        let pboard = NSPasteboard.general
        pboard.clearContents()
        pboard.writeObjects([url as NSURL])
        NSWorkspace.shared.activateFileViewerSelecting([url])
        Log.say("export", "path copied to clipboard; opened in Finder for sharing")
    }
}
