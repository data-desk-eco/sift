import Foundation
import Testing
@testable import SiftCore

private func body(_ json: String) -> Data { Data(json.utf8) }

/// Tests share a stub queue, so they run serialised — `.serialized`
/// guarantees no two run concurrently within the suite.
@Suite(.serialized) struct AlephClientRetryTests {

    init() { StubURLProtocol.reset() }

    @Test func rejectsNonHTTPScheme() {
        #expect(throws: SiftError.self) {
            _ = try AlephClient(baseURL: "file:///etc/passwd", apiKey: "k")
        }
        #expect(throws: SiftError.self) {
            _ = try AlephClient(baseURL: "javascript:alert(1)", apiKey: "k")
        }
    }

    @Test func acceptsHTTPSAndHTTP() throws {
        _ = try AlephClient(baseURL: "https://aleph.example.org", apiKey: "k")
        _ = try AlephClient(baseURL: "http://localhost:8080", apiKey: "k")
    }

    @Test func returnsBodyOn200() async throws {
        StubURLProtocol.enqueue(.init(
            status: 200, headers: [:], body: body(#"{"results":[],"total":0}"#)
        ))
        let client = try AlephClient(
            baseURL: "https://aleph.example.org",
            apiKey: "k",
            sessionConfiguration: stubbedConfig()
        )
        let json = try await client.get("/entities", params: ["q": "x"])
        #expect(json["total"] as? Int == 0)
        #expect(StubURLProtocol.recordedRequests().count == 1)
    }

    @Test func retriesOn429ThenSucceeds() async throws {
        StubURLProtocol.enqueue(.init(
            status: 429, headers: ["Retry-After": "0"],
            body: body(#"{"message":"slow down"}"#)
        ))
        StubURLProtocol.enqueue(.init(
            status: 200, headers: [:], body: body(#"{"total":1}"#)
        ))
        let client = try AlephClient(
            baseURL: "https://aleph.example.org",
            apiKey: "k",
            retryPolicy: .init(maxAttempts: 3, baseBackoff: 0.0, maxBackoff: 0.0),
            sessionConfiguration: stubbedConfig()
        )
        let json = try await client.get("/entities", params: nil)
        #expect(json["total"] as? Int == 1)
        #expect(StubURLProtocol.recordedRequests().count == 2)
    }

    @Test func retriesOn5xxWithExponentialBackoff() async throws {
        StubURLProtocol.enqueue(.init(status: 503, headers: [:], body: Data()))
        StubURLProtocol.enqueue(.init(status: 502, headers: [:], body: Data()))
        StubURLProtocol.enqueue(.init(
            status: 200, headers: [:], body: body(#"{"total":2}"#)
        ))
        let client = try AlephClient(
            baseURL: "https://aleph.example.org",
            apiKey: "k",
            retryPolicy: .init(maxAttempts: 4, baseBackoff: 0.0, maxBackoff: 0.0),
            sessionConfiguration: stubbedConfig()
        )
        let json = try await client.get("/entities", params: nil)
        #expect(json["total"] as? Int == 2)
        #expect(StubURLProtocol.recordedRequests().count == 3)
    }

    @Test func givesUpAfterMaxAttempts() async throws {
        for _ in 0..<3 {
            StubURLProtocol.enqueue(.init(status: 503, headers: [:], body: Data()))
        }
        let client = try AlephClient(
            baseURL: "https://aleph.example.org",
            apiKey: "k",
            retryPolicy: .init(maxAttempts: 3, baseBackoff: 0.0, maxBackoff: 0.0),
            sessionConfiguration: stubbedConfig()
        )
        await #expect(throws: SiftError.self) {
            _ = try await client.get("/entities", params: nil)
        }
        #expect(StubURLProtocol.recordedRequests().count == 3)
    }

    @Test func doesNotRetryAuthErrors() async throws {
        StubURLProtocol.enqueue(.init(
            status: 401, headers: [:], body: body(#"{"message":"bad key"}"#)
        ))
        let client = try AlephClient(
            baseURL: "https://aleph.example.org",
            apiKey: "k",
            retryPolicy: .init(maxAttempts: 4, baseBackoff: 0.0, maxBackoff: 0.0),
            sessionConfiguration: stubbedConfig()
        )
        await #expect(throws: SiftError.self) {
            _ = try await client.get("/entities", params: nil)
        }
        #expect(StubURLProtocol.recordedRequests().count == 1)
    }

    @Test func queryParamsAreSerialized() async throws {
        StubURLProtocol.enqueue(.init(
            status: 200, headers: [:], body: body("{}")
        ))
        let client = try AlephClient(
            baseURL: "https://aleph.example.org",
            apiKey: "k",
            sessionConfiguration: stubbedConfig()
        )
        _ = try await client.get("/entities", params: [
            "q": "acme",
            "filter:schemata": ["Email", "Document"],
            "limit": 10,
            "verbose": true,
        ])
        guard let url = StubURLProtocol.recordedRequests().first else {
            Issue.record("no recorded request")
            return
        }
        let query = url.query ?? ""
        #expect(query.contains("q=acme"))
        #expect(query.contains("filter:schemata=Email"))
        #expect(query.contains("filter:schemata=Document"))
        #expect(query.contains("limit=10"))
        #expect(query.contains("verbose=true"))
    }
}
