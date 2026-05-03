import Foundation
import Testing
@testable import SiftCore

@Suite(.serialized) struct RunRegistryTests {

    /// Run `block` with `ALEPH_SESSION_DIR` pointed at a fresh tmp
    /// research root inside the test's `SIFT_HOME`. RunRegistry then
    /// resolves session dirs there instead of trying to find a
    /// mounted vault.
    private func withResearchRoot<T>(_ block: (URL) throws -> T) throws -> T {
        try withTempHome { home in
            let root = home.appending(path: "research")
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: true
            )
            return try withEnv(["ALEPH_SESSION_DIR": root.path]) {
                try block(root)
            }
        }
    }

    /// Build a freshly-rooted RunState whose sessionDir is a real
    /// directory under `root`. Tests that don't care about the dir
    /// existing on disk can skip `mkdir`, but most do.
    private func makeState(_ name: String, root: URL) -> RunState {
        let dir = root.appending(path: name)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        return RunState(
            session: name, sessionDir: dir.path,
            logPath: dir.appending(path: "auto.log").path,
            prompt: "test", pid: getpid(),
            startedAt: Int(Date().timeIntervalSince1970)
        )
    }

    @Test func writeReadRoundTrip() throws {
        try withResearchRoot { root in
            try RunRegistry.write(makeState("acme-corp", root: root))
            let read = RunRegistry.read("acme-corp")
            #expect(read?.session == "acme-corp")
            #expect(read?.status == .running)
            #expect(read?.sessionDir == root.appending(path: "acme-corp").path)
            #expect(read?.logPath == root.appending(path: "acme-corp/auto.log").path)
        }
    }

    @Test func writeRejectsInvalidSessionName() throws {
        try withResearchRoot { root in
            #expect(throws: SiftError.self) {
                try RunRegistry.write(makeState("../escape", root: root))
            }
        }
    }

    @Test func readReturnsNilForInvalidName() throws {
        try withResearchRoot { _ in
            #expect(RunRegistry.read("../escape") == nil)
            #expect(RunRegistry.read("") == nil)
        }
    }

    @Test func readReturnsNilForCorruptJSON() throws {
        try withResearchRoot { root in
            let dir = root.appending(path: "junk")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try "not json".write(
                to: RunRegistry.sidecarURL(for: dir),
                atomically: true, encoding: .utf8
            )
            #expect(RunRegistry.read("junk") == nil)
        }
    }

    @Test func renamingSessionDirRenamesTheSession() throws {
        try withResearchRoot { root in
            try RunRegistry.write(makeState("before", root: root))
            try FileManager.default.moveItem(
                at: root.appending(path: "before"),
                to: root.appending(path: "after")
            )
            // Old name is gone, new name resolves to the same payload.
            #expect(RunRegistry.read("before") == nil)
            let read = RunRegistry.read("after")
            #expect(read?.session == "after")
            #expect(read?.sessionDir == root.appending(path: "after").path)
        }
    }

    @Test func listSortsByStartedAtDescending() throws {
        try withResearchRoot { root in
            var s1 = makeState("first", root: root)
            s1.startedAt = 1000
            var s2 = makeState("second", root: root)
            s2.startedAt = 2000
            var s3 = makeState("third", root: root)
            s3.startedAt = 1500
            try RunRegistry.write(s1)
            try RunRegistry.write(s2)
            try RunRegistry.write(s3)
            let names = RunRegistry.list().map(\.session)
            #expect(names == ["second", "third", "first"])
        }
    }

    @Test func listSkipsDirsWithoutSidecar() throws {
        try withResearchRoot { root in
            try RunRegistry.write(makeState("real", root: root))
            // A bare directory (e.g. an aborted `sift auto` that never
            // finished prepare) should be ignored, not crash list().
            try FileManager.default.createDirectory(
                at: root.appending(path: "ghost"),
                withIntermediateDirectories: true
            )
            let names = RunRegistry.list().map(\.session)
            #expect(names == ["real"])
        }
    }

    @Test func mostRecentReturnsNewestStartedAt() throws {
        try withResearchRoot { root in
            var s1 = makeState("old", root: root)
            s1.startedAt = 1
            var s2 = makeState("new", root: root)
            s2.startedAt = 9999
            try RunRegistry.write(s1)
            try RunRegistry.write(s2)
            #expect(RunRegistry.mostRecent()?.session == "new")
        }
    }

    @Test func updateMutatesInPlace() throws {
        try withResearchRoot { root in
            try RunRegistry.write(makeState("acme", root: root))
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
        try withResearchRoot { root in
            try RunRegistry.write(makeState("acme", root: root))
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
        try withResearchRoot { _ in
            // Should not throw when session doesn't exist.
            try RunRegistry.update("nonexistent") { $0.status = .failed }
        }
    }

    @Test func removeDeletesSidecar() throws {
        try withResearchRoot { root in
            try RunRegistry.write(makeState("acme", root: root))
            #expect(RunRegistry.read("acme") != nil)
            RunRegistry.remove("acme")
            #expect(RunRegistry.read("acme") == nil)
            // Removing the sidecar leaves the session dir intact —
            // the user's report.md / findings.db live there.
            #expect(FileManager.default.fileExists(
                atPath: root.appending(path: "acme").path
            ))
        }
    }

    @Test func researchRootIsNilWhenUnset() {
        withTempHome { _ in
            // No ALEPH_SESSION_DIR override and no mounted vault — the
            // menu bar / status command should see an empty list, not
            // fall back to anything that could prompt for a passphrase.
            #expect(RunRegistry.researchRoot() == nil)
            #expect(RunRegistry.list().isEmpty)
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
