import Foundation
import Testing
@testable import SiftCore

@Suite(.serialized) struct ForgeProxyTests {

    @Test func healthCheckReturnsFalseOnClosedPort() {
        // A port nothing is bound to. URLSession returns an error;
        // healthCheck should swallow it and report false (not throw,
        // not hang). 1.5 s wall ceiling per the function's internal
        // timeout — the test exits well inside that.
        #expect(ForgeProxy.healthCheck(port: 1, timeout: 0.5) == false)
    }

    @Test func stopIsSilentNoopWithoutPidfile() throws {
        // No pidfile in a fresh SIFT_HOME — stop() must not throw,
        // must not log noise, and must not leave anything behind.
        try withTempHome { home in
            let pidPath = home.appending(path: "forge-proxy.pid")
            #expect(!FileManager.default.fileExists(atPath: pidPath.path))
            // No assert on side-effects beyond "doesn't throw" — the
            // pidfile-absent path is the boring one.
            ForgeProxy.stop()
            #expect(!FileManager.default.fileExists(atPath: pidPath.path))
        }
    }

    @Test func stopIfIdleNoopsWhenNoRunsActive() throws {
        // No registry entries, no pidfile. stopIfIdle() should reach
        // stop() and silently return.
        try withTempHome { _ in
            #expect(RunRegistry.active().isEmpty)
            ForgeProxy.stopIfIdle()
        }
    }

    @Test func defaultPortMatchesBackendConstant() {
        // Backend.defaultProxyPort is the single source of truth pi
        // gets pointed at; ForgeProxy.start() must bind the same port.
        #expect(Backend.defaultProxyPort == ForgeProxy.defaultProxyPort)
    }
}
