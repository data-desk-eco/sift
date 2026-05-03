import Foundation
import Testing
@testable import SiftCore

@Suite(.serialized) struct RunRegistryTests {

    /// `RunRegistry.list()` filters by sessionDir existence on disk, so
    /// `makeState` plants a real directory under the test's temp home.
    /// Cleanup happens automatically when `withTempHome` returns.
    private func makeState(_ name: String, home: URL) -> RunState {
        let sessionDir = home.appending(path: "sessions/\(name)")
        try? FileManager.default.createDirectory(
            at: sessionDir, withIntermediateDirectories: true
        )
        return RunState(
            session: name, sessionDir: sessionDir.path,
            logPath: sessionDir.appending(path: "auto.log").path,
            prompt: "test", pid: getpid(),
            startedAt: Int(Date().timeIntervalSince1970)
        )
    }

    @Test func writeReadRoundTrip() throws {
        try withTempHome { home in
            try RunRegistry.write(makeState("acme-corp", home: home))
            let read = RunRegistry.read("acme-corp")
            #expect(read?.session == "acme-corp")
            #expect(read?.status == .running)
        }
    }

    @Test func writeRejectsInvalidSessionName() {
        withTempHome { home in
            #expect(throws: SiftError.self) {
                try RunRegistry.write(makeState("../escape", home: home))
            }
        }
    }

    @Test func readReturnsNilForInvalidName() {
        withTempHome { _ in
            #expect(RunRegistry.read("../escape") == nil)
            #expect(RunRegistry.read("") == nil)
        }
    }

    @Test func readReturnsNilForCorruptJSON() throws {
        try withTempHome { _ in
            try Paths.ensure(Paths.runDir)
            let path = Paths.runDir.appending(path: "junk.json")
            try "not json".write(to: path, atomically: true, encoding: .utf8)
            #expect(RunRegistry.read("junk") == nil)
        }
    }

    @Test func readRejectsTraversalSessionInPayload() throws {
        try withTempHome { _ in
            try Paths.ensure(Paths.runDir)
            // Hand-craft a JSON file whose `session` field tries to
            // escape — read() should reject it as malformed.
            let path = Paths.runDir.appending(path: "evil.json")
            let payload = """
                {"session":"../../etc/passwd","session_dir":"/tmp",
                 "log_path":"/dev/null","prompt":"x","pid":1,
                 "started_at":1,"status":"running","last_scope":"",
                 "last_message":"","last_event_at":1}
                """
            try payload.write(to: path, atomically: true, encoding: .utf8)
            #expect(RunRegistry.read(at: path) == nil)
        }
    }

    @Test func listSortsByStartedAtDescending() throws {
        try withTempHome { home in
            var s1 = makeState("first", home: home)
            s1.startedAt = 1000
            var s2 = makeState("second", home: home)
            s2.startedAt = 2000
            var s3 = makeState("third", home: home)
            s3.startedAt = 1500
            try RunRegistry.write(s1)
            try RunRegistry.write(s2)
            try RunRegistry.write(s3)
            let names = RunRegistry.list().map(\.session)
            #expect(names == ["second", "third", "first"])
        }
    }

    @Test func listDropsEntriesWhoseSessionDirIsMissing() throws {
        try withTempHome { home in
            let live = makeState("alive", home: home)
            let ghost = makeState("ghost", home: home)
            try RunRegistry.write(live)
            try RunRegistry.write(ghost)
            // Simulate the vault going away (or a different vault being
            // mounted): the JSON survives, the directory does not.
            try FileManager.default.removeItem(atPath: ghost.sessionDir)
            let names = RunRegistry.list().map(\.session)
            #expect(names == ["alive"])
        }
    }

    @Test func mostRecentReturnsNewestStartedAt() throws {
        try withTempHome { home in
            var s1 = makeState("old", home: home)
            s1.startedAt = 1
            var s2 = makeState("new", home: home)
            s2.startedAt = 9999
            try RunRegistry.write(s1)
            try RunRegistry.write(s2)
            #expect(RunRegistry.mostRecent()?.session == "new")
        }
    }

    @Test func updateMutatesInPlace() throws {
        try withTempHome { home in
            try RunRegistry.write(makeState("acme", home: home))
            try RunRegistry.update("acme") { st in
                st.lastScope = "tool"
                st.lastMessage = "search"
            }
            let read = RunRegistry.read("acme")
            #expect(read?.lastScope == "tool")
            #expect(read?.lastMessage == "search")
            #expect(read?.status == .running)  // unchanged
        }
    }

    @Test func updateIfRunningSkipsTerminalStates() throws {
        try withTempHome { home in
            try RunRegistry.write(makeState("acme", home: home))
            try RunRegistry.update("acme") { $0.status = .stopped }

            // Daemon's per-event update arrives after a stop — it must
            // not flip status back to .running or overwrite .stopped.
            try RunRegistry.updateIfRunning("acme") { st in
                st.lastScope = "tool"
                st.lastMessage = "should-not-stick"
            }
            let read = RunRegistry.read("acme")
            #expect(read?.status == .stopped)
            #expect(read?.lastScope == "")  // never updated
        }
    }

    @Test func updateOnAbsentSessionIsSilent() throws {
        try withTempHome { _ in
            // Should not throw when session doesn't exist.
            try RunRegistry.update("nonexistent") { $0.status = .failed }
        }
    }

    @Test func removeDeletesFile() throws {
        try withTempHome { home in
            try RunRegistry.write(makeState("acme", home: home))
            #expect(RunRegistry.read("acme") != nil)
            RunRegistry.remove("acme")
            #expect(RunRegistry.read("acme") == nil)
        }
    }

    @Test func pidAliveReturnsTrueForCurrentProcess() {
        #expect(RunRegistry.pidAlive(getpid()))
    }

    @Test func pidAliveReturnsFalseForNonExistentPid() {
        // Pick a pid astronomically unlikely to exist on this Mac.
        #expect(!RunRegistry.pidAlive(999_999))
    }
}
