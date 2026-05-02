import AppKit
import ArgumentParser
import Foundation
import SiftCore

/// Print or render a lead's `report.md`. Default mode cats the markdown
/// to stdout (the agent use case — read prior leads' findings without a
/// separate viewer); `--format html` drops the user back into the old
/// `sift export` flow with Spotlight tagging and the share sheet.
struct ReportCommand: SiftSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "report",
        abstract: "Print or render a lead's report.md.",
        discussion: """
            Default cats the lead's report.md to stdout — useful for an agent
            consolidating findings across leads. With --format html, renders
            to HTML with alias→Aleph entity links and opens it in the
            browser. With --list, prints every lead that has a report.md.

            <LEAD> resolution when omitted: cwd's report.md → ALEPH_SESSION_DIR
            → most recently modified lead under the vault.
            """
    )

    @Argument(help: "lead name (defaults to cwd → active session → most recent)")
    var lead: String?

    @Option(help: "output format: md (stdout) or html (rendered, opens in browser)")
    var format: String = "md"

    @Option(name: [.short, .customLong("out")],
            help: "HTML output path (default: report.html alongside report.md)")
    var out: String?

    @Option(help: "Aleph base URL for entity links (default: stored ALEPH_URL)")
    var server: String?

    @Flag(name: .customLong("no-open"),
          help: "(html only) don't pop the rendered HTML in the default browser")
    var noOpen: Bool = false

    @Flag(help: "(html only) show a macOS share sheet instead of opening in browser")
    var share: Bool = false

    @Flag(help: "list every lead that has a report.md, then exit")
    var list: Bool = false

    func execute() async throws {
        if list {
            try printList()
            return
        }
        let srcURL = try resolveSource()
        switch format.lowercased() {
        case "md", "markdown":
            try catMarkdown(srcURL)
        case "html":
            try renderHTML(srcURL: srcURL)
        default:
            throw SiftError(
                "unknown --format: \(format)",
                suggestion: "use 'md' (default) or 'html'"
            )
        }
    }

    // MARK: - Markdown mode

    private func catMarkdown(_ srcURL: URL) throws {
        let data = try Data(contentsOf: srcURL)
        FileHandle.standardOutput.write(data)
        if let last = data.last, last != 0x0a {
            FileHandle.standardOutput.write(Data([0x0a]))
        }
    }

    // MARK: - HTML mode (the old `sift export`)

    private func renderHTML(srcURL: URL) throws {
        let dstURL: URL
        if let outPath = out {
            dstURL = URL(filePath: (outPath as NSString).expandingTildeInPath)
        } else {
            dstURL = srcURL.deletingPathExtension().appendingPathExtension("html")
        }

        let serverURL: String
        if let s = server, !s.isEmpty {
            serverURL = s
        } else if let env = ProcessInfo.processInfo.environment["ALEPH_URL"], !env.isEmpty {
            serverURL = env
        } else if let s = (try? SecretsStore.load())?.alephURL, !s.isEmpty {
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

        var msg = "[report]   \(srcURL.path) → \(dstURL.path)  (\(counts.linked) aliases linked"
        if counts.unresolved > 0 { msg += ", \(counts.unresolved) unresolved" }
        msg += ")"
        print(msg)

        applySpotlight(to: dstURL, src: srcURL)

        if share {
            showShareSheet(for: dstURL)
        } else if !noOpen {
            NSWorkspace.shared.open(dstURL)
        }
    }

    // MARK: - List mode

    private func printList() throws {
        let researchDir = try researchRoot()
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: researchDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey]
        )) ?? []
        struct Row { let name: String; let mtime: TimeInterval; let bytes: Int }
        var rows: [Row] = []
        for url in entries {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            else { continue }
            let report = url.appending(path: "report.md")
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: report.path)
            else { continue }
            let m = ((attrs[.modificationDate] as? Date)?.timeIntervalSince1970) ?? 0
            let s = (attrs[.size] as? Int) ?? 0
            rows.append(Row(name: url.lastPathComponent, mtime: m, bytes: s))
        }
        rows.sort { $0.mtime > $1.mtime }
        if rows.isEmpty {
            print("(no leads have a report.md yet)")
            return
        }
        let now = Date().timeIntervalSince1970
        let cells = rows.map { r -> [String] in
            [r.name, Self.formatAge(now - r.mtime), Self.formatBytes(r.bytes)]
        }
        print(Table.render(cells, headers: ["lead", "updated", "size"]))
    }

    private func researchRoot() throws -> URL {
        let env = ProcessInfo.processInfo.environment
        if let dir = env["ALEPH_SESSION_DIR"] {
            return URL(filePath: dir)
        }
        if let mp = VaultService().findExistingMount() {
            return mp.appending(path: "research")
        }
        throw SiftError(
            "no lead directory available",
            suggestion: "unlock the vault (`sift vault unlock`) or pass an explicit lead"
        )
    }

    // MARK: - Source resolution

    private func resolveSource() throws -> URL {
        if let name = lead {
            try SessionName.validate(name)
            let researchDir = try researchRoot()
            let report = researchDir.appending(path: name).appending(path: "report.md")
            guard FileManager.default.fileExists(atPath: report.path) else {
                throw SiftError(
                    "no report.md for lead: \(name)",
                    suggestion: "run `sift report --list` to see leads with reports"
                )
            }
            return report
        }
        let cwd = FileManager.default.currentDirectoryPath
        let cwdReport = URL(filePath: cwd).appending(path: "report.md")
        if FileManager.default.fileExists(atPath: cwdReport.path) {
            return cwdReport
        }
        let researchDir = try researchRoot()
        let candidates = (try? FileManager.default.contentsOfDirectory(
            at: researchDir, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        let reports = candidates.compactMap { url -> URL? in
            let rep = url.appending(path: "report.md")
            return FileManager.default.fileExists(atPath: rep.path) ? rep : nil
        }
        guard let latest = reports.max(by: { Self.mtime($0) < Self.mtime($1) }) else {
            throw SiftError(
                "no report.md found under \(researchDir.path)",
                suggestion: "run `sift auto \"...\"` to create one, or pass a lead name"
            )
        }
        return latest
    }

    // MARK: - Helpers

    private static func mtime(_ url: URL) -> TimeInterval {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return ((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970) ?? 0
    }

    private static func formatAge(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86_400 { return "\(s / 3600)h" }
        return "\(s / 86_400)d"
    }

    private static func formatBytes(_ n: Int) -> String {
        let kb = 1024, mb = 1024 * 1024
        if n >= mb { return String(format: "%.1fM", Double(n) / Double(mb)) }
        if n >= kb { return "\(n / kb)K" }
        return "\(n)B"
    }

    private func applySpotlight(to dst: URL, src: URL) {
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
        Log.say("report", "path copied to clipboard; opened in Finder for sharing")
    }
}
