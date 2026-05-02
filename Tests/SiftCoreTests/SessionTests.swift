import Foundation
import Testing
@testable import SiftCore

/// `Session.dbPath()` reads env vars, so tests must not race each
/// other on `setenv`.
@Suite(.serialized) struct SessionTests {

    private func withEnv<T>(_ overrides: [String: String?], _ block: () throws -> T) rethrows -> T {
        var prior: [String: String?] = [:]
        for (k, _) in overrides {
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

    @Test func usesAlephDbPathOverride() throws {
        let path = try withEnv([
            "ALEPH_DB_PATH": "/tmp/explicit/path.sqlite",
            "ALEPH_SESSION_DIR": "/tmp/should-be-ignored",
        ]) { try Session.dbPath().path }
        #expect(path == "/tmp/explicit/path.sqlite")
    }

    @Test func expandsTildeInOverride() throws {
        let path = try withEnv([
            "ALEPH_DB_PATH": "~/custom.sqlite",
            "ALEPH_SESSION_DIR": nil,
        ]) { try Session.dbPath().path }
        #expect(!path.hasPrefix("~"))
        #expect(path.hasSuffix("/custom.sqlite"))
    }

    @Test func fallsBackToSessionDirAlephSqlite() throws {
        let path = try withEnv([
            "ALEPH_DB_PATH": nil,
            "ALEPH_SESSION_DIR": "/tmp/some-session",
        ]) { try Session.dbPath().path }
        #expect(path == "/tmp/some-session/aleph.sqlite")
    }

    @Test func emptyOverridesAreIgnored() throws {
        let path = try withEnv([
            "ALEPH_DB_PATH": "",
            "ALEPH_SESSION_DIR": "/tmp/with-empty-override",
        ]) { try Session.dbPath().path }
        #expect(path == "/tmp/with-empty-override/aleph.sqlite")
    }
}
