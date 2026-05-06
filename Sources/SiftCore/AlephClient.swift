import Foundation

/// Aleph HTTP client. Auto-appends `/api/2` to bare hostnames so the
/// user can paste `https://aleph.occrp.org` into config without
/// remembering the path. Repeats array parameters
/// (`filter:schemata=A&filter:schemata=B`) the way Aleph expects.
///
/// Retries 429 (honoring `Retry-After`) and 5xx with exponential
/// backoff so a transient blip in the server doesn't kill an agent run
/// mid-investigation.
public actor AlephClient {
    public nonisolated let baseURL: String
    public nonisolated let serverName: String

    private let apiKey: String
    private let session: URLSession
    private let timeout: TimeInterval
    private let retryPolicy: RetryPolicy

    /// Tunable retry behaviour. Defaults are calibrated for the agent's
    /// hot path: enough retries to sail past a typical rate-limit
    /// window, short enough that a genuinely down server fails fast.
    public struct RetryPolicy: Sendable {
        public var maxAttempts: Int
        public var baseBackoff: TimeInterval
        /// Cap so a server-supplied `Retry-After: 600` doesn't pin the
        /// agent for ten minutes.
        public var maxBackoff: TimeInterval

        public static let `default` = RetryPolicy(
            maxAttempts: 4, baseBackoff: 1.0, maxBackoff: 30.0
        )

        public static let none = RetryPolicy(
            maxAttempts: 1, baseBackoff: 0, maxBackoff: 0
        )

        public init(maxAttempts: Int, baseBackoff: TimeInterval, maxBackoff: TimeInterval) {
            self.maxAttempts = max(1, maxAttempts)
            self.baseBackoff = baseBackoff
            self.maxBackoff = maxBackoff
        }
    }

    public init(
        baseURL: String,
        apiKey: String,
        serverName: String = "",
        timeout: TimeInterval = 30,
        retryPolicy: RetryPolicy = .default,
        sessionConfiguration: URLSessionConfiguration? = nil
    ) throws {
        let normalized = Self.normalize(baseURL)
        // Defence-in-depth: a stored ALEPH_URL of `file:///etc/passwd`
        // would otherwise be exfiltrated by URLSession on the first
        // request. Lock to http(s) so the only attack surface is the
        // configured Aleph instance.
        guard let parsed = URL(string: normalized),
              let scheme = parsed.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else {
            throw SiftError(
                "Aleph URL must use http or https",
                suggestion: "got: \(baseURL)"
            )
        }
        self.baseURL = normalized
        self.apiKey = apiKey
        self.serverName = serverName.isEmpty
            ? Self.deriveServerName(from: self.baseURL)
            : serverName
        self.timeout = timeout
        self.retryPolicy = retryPolicy

        let config = sessionConfiguration ?? URLSessionConfiguration.default
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

        return try await getWithRetry(url: url, path: path)
    }

    /// Issue the request with retry/backoff. Retries on:
    ///  - 429 (honors `Retry-After`)
    ///  - 5xx server errors
    ///  - Transient network errors (URLError.timedOut, .networkConnectionLost, …)
    /// Auth/4xx-other errors are surfaced immediately — retrying them
    /// would just burn time before the same outcome.
    private func getWithRetry(url: URL, path: String) async throws -> [String: Any] {
        var attempt = 0
        var lastError: Error?
        while attempt < retryPolicy.maxAttempts {
            attempt += 1
            do {
                let (data, response) = try await session.data(from: url)
                guard let http = response as? HTTPURLResponse else {
                    throw SiftError("non-HTTP response from \(path)")
                }

                if http.statusCode == 429 || (500...599).contains(http.statusCode) {
                    if attempt >= retryPolicy.maxAttempts {
                        throw parseError(data: data, status: http.statusCode)
                    }
                    let wait = retryDelay(for: http, attempt: attempt)
                    try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                    continue
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
            } catch let urlError as URLError where Self.isTransient(urlError) {
                lastError = urlError
                if attempt >= retryPolicy.maxAttempts { break }
                let wait = min(
                    retryPolicy.baseBackoff * pow(2, Double(attempt - 1)),
                    retryPolicy.maxBackoff
                )
                try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                continue
            } catch let siftError as SiftError {
                throw siftError
            } catch {
                throw SiftError(
                    "network error: \(error.localizedDescription)",
                    suggestion: "check connectivity and Aleph URL"
                )
            }
        }
        throw SiftError(
            "network error: \(lastError?.localizedDescription ?? "exhausted retries")",
            suggestion: "check connectivity and Aleph URL"
        )
    }

    /// Parse `Retry-After` header (RFC 7231 — seconds, or HTTP-date).
    /// Falls back to exponential backoff. Always clamped to maxBackoff.
    private func retryDelay(for http: HTTPURLResponse, attempt: Int) -> TimeInterval {
        let exponential = min(
            retryPolicy.baseBackoff * pow(2, Double(attempt - 1)),
            retryPolicy.maxBackoff
        )
        guard let raw = http.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespaces)
        else { return exponential }

        if let seconds = TimeInterval(raw) {
            return min(max(seconds, retryPolicy.baseBackoff), retryPolicy.maxBackoff)
        }
        // HTTP-date form. Parse via DateFormatter (RFC 1123).
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = formatter.date(from: raw) {
            return min(max(date.timeIntervalSinceNow, retryPolicy.baseBackoff),
                       retryPolicy.maxBackoff)
        }
        return exponential
    }

    private static func isTransient(_ error: URLError) -> Bool {
        switch error.code {
        case .timedOut, .networkConnectionLost, .notConnectedToInternet,
             .dnsLookupFailed, .cannotConnectToHost, .cannotFindHost,
             .resourceUnavailable:
            return true
        default:
            return false
        }
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
                suggestion: "check the Aleph API key with 'sift vault get ALEPH_API_KEY'"
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
