import Foundation
import Testing
@testable import SiftCore

// MARK: - Stub URLProtocol

/// Stubs URL responses so tests don't need a real Aleph instance.
/// Register canned responses with `enqueue`, then make requests
/// through any `URLSession` configured with `stubbedConfig()`.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {

    struct Stubbed {
        var status: Int
        var headers: [String: String]
        var body: Data
    }

    nonisolated(unsafe) static var queue: [Stubbed] = []
    nonisolated(unsafe) static var requestLog: [URL] = []
    static let lock = NSLock()

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        queue = []
        requestLog = []
    }

    static func enqueue(_ s: Stubbed) {
        lock.lock(); defer { lock.unlock() }
        queue.append(s)
    }

    /// Convenience: enqueue an HTTP 200 with a JSON body.
    static func enqueueJSON(_ json: String, status: Int = 200) {
        enqueue(.init(status: status, headers: [:], body: Data(json.utf8)))
    }

    static func popNext() -> Stubbed? {
        lock.lock(); defer { lock.unlock() }
        return queue.isEmpty ? nil : queue.removeFirst()
    }

    static func recordedRequests() -> [URL] {
        lock.lock(); defer { lock.unlock() }
        return requestLog
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let url = request.url {
            Self.lock.lock()
            Self.requestLog.append(url)
            Self.lock.unlock()
        }
        guard let stub = Self.popNext() else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: stub.status,
            httpVersion: "HTTP/1.1", headerFields: stub.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

func stubbedConfig() -> URLSessionConfiguration {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubURLProtocol.self]
    return config
}

// MARK: - Test fixtures

/// Build an `AlephClient` wired to the stub URLProtocol with retries
/// disabled — most command tests want determinism, not retry coverage.
func stubbedClient(serverName: String = "test") throws -> AlephClient {
    try AlephClient(
        baseURL: "https://aleph.example.org",
        apiKey: "k",
        serverName: serverName,
        retryPolicy: .none,
        sessionConfiguration: stubbedConfig()
    )
}

/// Open a fresh in-tmp `Store` and return it alongside its directory.
/// Caller is responsible for `try? FileManager.default.removeItem(at:)`
/// in a defer.
func tempStore(label: String = "test") throws -> (Store, URL) {
    let dir = FileManager.default.temporaryDirectory
        .appending(path: "sift-\(label)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let store = try Store(dbPath: dir.appending(path: "store.sqlite"))
    return (store, dir)
}
