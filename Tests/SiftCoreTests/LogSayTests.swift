import Foundation
import Testing
@testable import SiftCore

/// Stderr is process-global, so these run serialized.
@Suite(.serialized) struct LogSayTests {

    /// Reroute stderr through a pipe so we can assert what `Log.say`
    /// actually wrote.
    private func captureStderr(_ block: () -> Void) -> String {
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

    @Test func padsShortScopeToNineColumns() {
        let out = captureStderr { Log.say("init", "ready") }
        #expect(out == "[init]    ready\n")
    }

    @Test func leavesLongScopeUnpadded() {
        let out = captureStderr { Log.say("backend", "checking") }
        #expect(out == "[backend] checking\n")
    }

    @Test func handlesScopeOverflow() {
        let out = captureStderr { Log.say("verylong-scope", "msg") }
        #expect(out.hasPrefix("[verylong-scope]"))
        #expect(out.hasSuffix(" msg\n"))
    }
}
