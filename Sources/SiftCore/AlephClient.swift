import Foundation

/// Aleph HTTP client. Auto-appends `/api/2` to bare hostnames so the
/// user can paste `https://aleph.occrp.org` into config without
/// remembering the path. Repeats array parameters
/// (`filter:schemata=A&filter:schemata=B`) the way Aleph expects.
public actor AlephClient {
    public nonisolated let baseURL: String
    public nonisolated let serverName: String

    private let apiKey: String
    private let session: URLSession
    private let timeout: TimeInterval

    public init(
        baseURL: String,
        apiKey: String,
        serverName: String = "",
        timeout: TimeInterval = 30
    ) {
        self.baseURL = Self.normalize(baseURL)
        self.apiKey = apiKey
        self.serverName = serverName.isEmpty
            ? Self.deriveServerName(from: self.baseURL)
            : serverName
        self.timeout = timeout

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = timeout
        config.httpAdditionalHeaders = [
            "Authorization": "ApiKey \(apiKey)",
            "Accept": "application/json",
        ]
        self.session = URLSession(configuration: config)
    }

    /// Strip trailing slash; auto-append `/api/2` if no `/api/<digits>` path is set.
    static func normalize(_ raw: String) -> String {
        var url = raw.hasSuffix("/") ? String(raw.dropLast()) : raw
        let pattern = #"/api/v?\d+$"#
        if url.range(of: pattern, options: .regularExpression) == nil {
            url += "/api/2"
        }
        return url
    }

    /// Aleph's host short-name, used to namespace per-server caches and
    /// to label entity URLs in exported reports.
    static func deriveServerName(from baseURL: String) -> String {
        guard let host = URLComponents(string: baseURL)?.host?.lowercased(),
              !host.isEmpty
        else { return "" }
        let parts = host.split(separator: ".")
        let generic: Set<String> = ["aleph", "search", "bar", "www"]
        if let first = parts.first, generic.contains(String(first)), parts.count > 1 {
            return String(parts[1])
        }
        return parts.first.map(String.init) ?? ""
    }

    public func get(
        _ path: String,
        params: [String: Any]? = nil
    ) async throws -> [String: Any] {
        guard var components = URLComponents(string: "\(baseURL)\(path)") else {
            throw SiftError("invalid URL: \(baseURL)\(path)")
        }

        if let params {
            var items: [URLQueryItem] = []
            for (key, value) in params.sorted(by: { $0.key < $1.key }) {
                if value is NSNull { continue }
                if let arr = value as? [String] {
                    for v in arr { items.append(URLQueryItem(name: key, value: v)) }
                } else if let b = value as? Bool {
                    items.append(URLQueryItem(name: key, value: b ? "true" : "false"))
                } else {
                    items.append(URLQueryItem(name: key, value: "\(value)"))
                }
            }
            components.queryItems = items
        }

        guard let url = components.url else {
            throw SiftError("invalid query for \(path)")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: url)
        } catch {
            throw SiftError(
                "network error: \(error.localizedDescription)",
                suggestion: "check connectivity and Aleph URL"
            )
        }

        guard let http = response as? HTTPURLResponse else {
            throw SiftError("non-HTTP response from \(path)")
        }
        if http.statusCode >= 400 {
            throw parseError(data: data, status: http.statusCode)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let preview = String(data: data.prefix(120), encoding: .utf8) ?? "<binary>"
            throw SiftError(
                "non-JSON response from \(path) (content-type=\(http.value(forHTTPHeaderField: "content-type") ?? "?"))",
                suggestion: "check the URL points at the API root, e.g. https://aleph.example.org/api/2. got: \(preview)"
            )
        }
        return json
    }

    private func parseError(data: Data, status: Int) -> SiftError {
        var msg = ""
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let m = json["message"] as? String {
            msg = m.components(separatedBy: "\n").first ?? m
        } else if let text = String(data: data.prefix(200), encoding: .utf8) {
            msg = text
        }

        switch status {
        case 400 where msg.lowercased().contains("schema"):
            return SiftError(
                "server requires a schema filter for this query",
                suggestion: "add --type emails|docs|web|people|orgs"
            )
        case 401, 403:
            return SiftError(
                "auth failed (HTTP \(status)): \(msg)",
                suggestion: "check the Aleph API key in Keychain"
            )
        case 404:
            return SiftError("not found: \(msg)", suggestion: "verify the entity ID or alias")
        case 429:
            return SiftError("rate-limited by server", suggestion: "wait and retry")
        default:
            return SiftError("HTTP \(status): \(msg.isEmpty ? "request failed" : msg)")
        }
    }
}
