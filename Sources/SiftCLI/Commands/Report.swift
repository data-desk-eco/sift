import ArgumentParser
import Foundation
import SiftCore

/// Print a lead's `report.md` to stdout — the agent use case, reading prior
/// leads' findings without a separate viewer. report.md is self-contained
/// (it carries entity ids and Aleph links inline), so there's no HTML
/// render step. With --list, prints every lead that has a report.md.
struct ReportCommand: SiftSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "report",
        abstract: "Print a lead's report.md.",
        discussion: """
            Cats the lead's report.md to stdout — useful for an agent
            consolidating findings across leads. With --list, prints every
            lead that has a report.md.

            <LEAD> resolution when omitted: cwd's report.md → most
            recently modified run under the vault.
            """
    )

    @Argument(help: "lead name (defaults to cwd → active session → most recent)")
    var lead: String?

    @Flag(help: "list every lead that has a report.md, then exit")
    var list: Bool = false

    func execute() async throws {
        if list {
            try printList()
            return
        }
        let srcURL = try resolveSource()
        let data = try Data(contentsOf: srcURL)
        FileHandle.standardOutput.write(data)
        if let last = data.last, last != 0x0a {
            FileHandle.standardOutput.write(Data([0x0a]))
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
}
