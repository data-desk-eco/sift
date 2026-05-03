import Foundation
import Testing
@testable import SiftCore

/// Touches `~/.sift/active-lead`, so SIFT_HOME must point at a temp
/// dir. `withTempHome` (in TestSupport) holds a process-wide lock so
/// concurrent suites can't stomp our SIFT_HOME mid-test.
@Suite(.serialized) struct ActiveLeadTests {

    @Test func roundTripsValidName() {
        withTempHome { _ in
            #expect(ActiveLead.get() == nil)
            #expect(ActiveLead.set("acme-corp"))
            #expect(ActiveLead.get() == "acme-corp")
        }
    }

    @Test func setRejectsInvalidNames() {
        withTempHome { _ in
            #expect(!ActiveLead.set("../escape"))
            #expect(!ActiveLead.set(""))
            #expect(!ActiveLead.set(".hidden"))
            #expect(ActiveLead.get() == nil)
        }
    }

    @Test func clearRemovesLead() {
        withTempHome { _ in
            _ = ActiveLead.set("acme-corp")
            #expect(ActiveLead.clear())
            #expect(ActiveLead.get() == nil)
        }
    }

    @Test func clearOnAbsentLeadIsNoOp() {
        withTempHome { _ in
            #expect(ActiveLead.clear())
        }
    }

    @Test func corruptedLeadFileIsTreatedAsAbsent() throws {
        try withTempHome { _ in
            // Hand-craft a malicious lead value bypassing `set`.
            let path = Paths.siftHome.appending(path: "active-lead")
            try Paths.ensure(Paths.siftHome)
            try "../../etc/passwd\n".write(to: path, atomically: true, encoding: .utf8)
            #expect(ActiveLead.get() == nil)
        }
    }

    @Test func setTrimsWhitespace() {
        withTempHome { _ in
            #expect(ActiveLead.set("  acme-corp\n  "))
            #expect(ActiveLead.get() == "acme-corp")
        }
    }

    @Test func getReturnsNilWhenLeadDirMissing() throws {
        try withTempHome { home in
            let root = home.appending(path: "research")
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: true
            )
            try withEnv(["ALEPH_SESSION_DIR": root.path]) {
                _ = ActiveLead.set("acme-corp")
                // Dir doesn't exist yet → stale pointer.
                #expect(ActiveLead.get() == nil)
                // Create it → resolves cleanly.
                try FileManager.default.createDirectory(
                    at: root.appending(path: "acme-corp"),
                    withIntermediateDirectories: true
                )
                #expect(ActiveLead.get() == "acme-corp")
                // Simulate rename: dir gone again.
                try FileManager.default.removeItem(
                    at: root.appending(path: "acme-corp")
                )
                #expect(ActiveLead.get() == nil)
            }
        }
    }

    @Test func getReturnsNameWhenResearchRootUnreachable() {
        withTempHome { _ in
            // No ALEPH_SESSION_DIR, no mounted vault — fall back to
            // returning the raw name; the caller surfaces the error.
            _ = ActiveLead.set("acme-corp")
            #expect(ActiveLead.get() == "acme-corp")
        }
    }
}
