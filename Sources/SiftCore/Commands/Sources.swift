import Foundation

public struct SourcesInput: Sendable {
    public var grep: String?
    public var limit: Int
    public init(grep: String? = nil, limit: Int = 50) {
        self.grep = grep; self.limit = limit
    }
}

public func runSources(
    client: AlephClient, store: Store, input: SourcesInput
) async throws -> String {
    let data = try await client.get("/collections", params: ["limit": input.limit])
    var results = (data["results"] as? [[String: Any]]) ?? []
    if let g = input.grep?.lowercased(), !g.isEmpty {
        results = results.filter {
            ($0["label"] as? String)?.lowercased().contains(g) ?? false
        }
    }
    if results.isEmpty {
        return Render.envelope("sources", "(none matching)")
    }
    let rows: [[String]] = results.map {
        let idValue = $0["id"] ?? $0["foreign_id"] ?? ""
        let id = "\(idValue)"
        let label = Render.short($0["label"] as? String ?? "", width: 80)
        let count: String
        if let n = $0["count"] as? Int { count = String(n) }
        else if let n = $0["count"] as? Int64 { count = String(n) }
        else { count = "" }
        return [id, label, count]
    }
    let header = input.grep.map { "sources --grep \($0)" } ?? "sources"
    return Render.envelope(header, Table.render(rows, headers: ["id", "label", "count"]))
}
