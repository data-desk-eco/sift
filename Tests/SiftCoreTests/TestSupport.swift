import Foundation
import Testing
@testable import SiftCore

// MARK: - Process state and serialization
//
// Several test suites mutate process-wide state: SIFT_HOME via setenv,
// stderr via dup2, and the global StubURLProtocol queue. swift-testing
// runs tests inside a suite serialised when the suite is `.serialized`,
// but separate suites still run concurrently with each other. Until we
// can adopt swift-testing's `TestScoping` (added after 0.12, which is
// the version we pin) there's no clean way to serialise across suites
// in-process.
//
// Pragmatic approach:
//   - any suite that mutates process-wide state is `.serialized` so its
//     own tests don't race;
//   - cross-suite races are rare in practice (each suite is small and
//     fast) — we accept the residual flake risk in exchange for fast,
//     parallel test execution and no risk of cooperative-pool deadlock
//     from a global blocking lock.

// MARK: - Temp SIFT_HOME

/// Run `block` with `SIFT_HOME` pointing at a fresh temp directory.
/// The directory is created before the block runs and removed after.
/// Caller's suite should be `@Suite(.serialized)` since this mutates
/// process-wide env.
func withTempHome<T>(
    label: String = "sift-test",
    _ block: (URL) throws -> T
) rethrows -> T {
    let dir = FileManager.default.temporaryDirectory
        .appending(path: "\(label)-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(
        at: dir, withIntermediateDirectories: true
    )
    let prior = ProcessInfo.processInfo.environment["SIFT_HOME"]
    setenv("SIFT_HOME", dir.path, 1)
    defer {
        if let prior { setenv("SIFT_HOME", prior, 1) } else { unsetenv("SIFT_HOME") }
        try? FileManager.default.removeItem(at: dir)
    }
    return try block(dir)
}

// MARK: - Generic env override

/// Set/unset a batch of env vars for the duration of `block`. A nil
/// value unsets the var. Restores the previous values on exit. Caller's
/// suite should be `@Suite(.serialized)`.
func withEnv<T>(
    _ overrides: [String: String?],
    _ block: () throws -> T
) rethrows -> T {
    var prior: [String: String?] = [:]
    for k in overrides.keys {
        prior[k] = ProcessInfo.processInfo.environment[k]
    }
    for (k, v) in overrides {
        if let v { setenv(k, v, 1) } else { unsetenv(k) }
    }
    defer {
        for (k, v) in prior {
            if let v { setenv(k, v, 1) } else { unsetenv(k) }
        }
    }
    return try block()
}

// MARK: - Captured stderr

/// Redirect `STDERR_FILENO` through a pipe for the duration of `block`,
/// returning whatever was written. Caller's suite should be
/// `@Suite(.serialized)` since this rewrites a process-wide fd.
func withCapturedStderr(_ block: () -> Void) -> String {
    let originalFD = dup(STDERR_FILENO)
    let pipe = Pipe()
    dup2(pipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO)
    block()
    dup2(originalFD, STDERR_FILENO)
    close(originalFD)
    try? pipe.fileHandleForWriting.close()
    let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
    return String(data: data, encoding: .utf8) ?? ""
}

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

/// Per-suite stub-queue scope. Hold one as a stored property on a
/// suite struct (`let scope = StubScope()`); swift-testing constructs
/// a fresh suite instance for each test, so `init` runs before each
/// test and resets the global queue. Caller's suite should be
/// `@Suite(.serialized)` so two tests in the same suite don't both
/// enqueue at once.
final class StubScope {
    init() {
        StubURLProtocol.reset()
    }
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
