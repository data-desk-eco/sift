import Foundation

public struct DownloadInput: Sendable {
    public var alias: String
    public init(alias: String) { self.alias = alias }
}

/// Pull a document entity's underlying file (the docx/pdf/xlsx behind a
/// search hit) into `<research>/files/` so the agent can inspect it locally
/// with plain bash — `read` only ever sees Aleph's extracted bodyText. The
/// file link lives in the entity's `links.file`; entities without stored
/// content (folders, web pages, parties) have none.
public func runDownload(
    client: AlephClient, store: Store, input: DownloadInput
) async throws -> String {
    let eid = try store.resolveAlias(input.alias)
    let entity = try await client.get("/entities/\(eid)")
    let links = entity["links"] as? [String: Any] ?? [:]
    guard let link = (links["file"] ?? links["pdf"] ?? links["csv"]) as? String,
          !link.isEmpty
    else {
        throw SiftError(
            "\(input.alias) has no downloadable file",
            suggestion: "only documents with stored content download; try `sift read \(input.alias)`"
        )
    }
    let props = entity["properties"] as? [String: Any] ?? [:]
    // sit alongside aleph.sqlite (the shared research dir under a sweep), so
    // downloads land in <research>/files/ next to the segments.
    let dir = store.dbPath.deletingLastPathComponent().appending(path: "files")
    try Paths.ensure(dir)
    let dest = dir.appending(path: downloadName(alias: input.alias, props: props, link: link))
    let bytes = try await client.download(from: link, to: dest)
    return Render.envelope("download \(input.alias)", """
    saved:  \(dest.path)
    size:   \(byteString(bytes))
    inspect locally with bash (e.g. textutil, pdftotext, unzip -l, file)
    """)
}

/// `<alias>-<fileName>`, prefixed so two hits with the same fileName don't
/// clobber and so the agent can see at a glance which alias a file came
/// from. Falls back to the title, then the link's last path component.
private func downloadName(alias: String, props: [String: Any], link: String) -> String {
    var base = Render.firstString(props["fileName"])
        ?? Render.firstString(props["title"])
        ?? URL(string: link)?.lastPathComponent
        ?? ""
    if base.isEmpty { base = "file" }
    let safe = base.components(separatedBy: CharacterSet(charactersIn: "/\\\u{0}")).joined(separator: "_")
    return "\(alias)-\(safe)"
}

private func byteString(_ n: Int) -> String {
    let units = ["B", "KB", "MB", "GB"]
    var v = Double(n), i = 0
    while v >= 1024, i < units.count - 1 { v /= 1024; i += 1 }
    return i == 0 ? "\(n) B" : String(format: "%.1f %@", v, units[i])
}
