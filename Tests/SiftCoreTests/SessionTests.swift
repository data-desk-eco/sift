import Foundation
import Testing
@testable import SiftCore

/// `Session.dbPath()` reads env vars. `withEnv` (in TestSupport) holds
/// a process-wide lock so concurrent suites can't race on setenv.
@Suite(.serialized) struct SessionTests {

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
