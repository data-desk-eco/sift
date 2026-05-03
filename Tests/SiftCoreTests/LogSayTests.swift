import Foundation
import Testing
@testable import SiftCore

/// Stderr is process-global. `withCapturedStderr` (in TestSupport)
/// holds a process-wide lock so concurrent suites' logging can't bleed
/// into our captured output.
@Suite(.serialized) struct LogSayTests {

    @Test func padsShortScopeToNineColumns() {
        let out = withCapturedStderr { Log.say("init", "ready") }
        #expect(out == "[init]    ready\n")
    }

    @Test func leavesLongScopeUnpadded() {
        let out = withCapturedStderr { Log.say("backend", "checking") }
        #expect(out == "[backend] checking\n")
    }

    @Test func handlesScopeOverflow() {
        let out = withCapturedStderr { Log.say("verylong-scope", "msg") }
        #expect(out.hasPrefix("[verylong-scope]"))
        #expect(out.hasSuffix(" msg\n"))
    }
}
