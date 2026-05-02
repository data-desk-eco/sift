import Foundation
import Testing
@testable import SiftCore

/// Touches `~/.sift/active-lead`, so SIFT_HOME must point at a temp
/// dir. The serialised trait keeps these from racing each other (and
/// any other test) on the shared SIFT_HOME the test runner sets.
@Suite(.serialized) struct ActiveLeadTests {

    private func withTempHome<T>(_ block: () throws -> T) rethrows -> T {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "sift-lead-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let prior = ProcessInfo.processInfo.environment["SIFT_HOME"]
        setenv("SIFT_HOME", dir.path, 1)
        defer {
            if let prior { setenv("SIFT_HOME", prior, 1) } else { unsetenv("SIFT_HOME") }
            try? FileManager.default.removeItem(at: dir)
        }
        return try block()
    }

    @Test func roundTripsValidName() {
        withTempHome {
            #expect(ActiveLead.get() == nil)
            #expect(ActiveLead.set("acme-corp"))
            #expect(ActiveLead.get() == "acme-corp")
        }
    }

    @Test func setRejectsInvalidNames() {
        withTempHome {
            #expect(!ActiveLead.set("../escape"))
            #expect(!ActiveLead.set(""))
            #expect(!ActiveLead.set(".hidden"))
            #expect(ActiveLead.get() == nil)
        }
    }

    @Test func clearRemovesLead() {
        withTempHome {
            _ = ActiveLead.set("acme-corp")
            #expect(ActiveLead.clear())
            #expect(ActiveLead.get() == nil)
        }
    }

    @Test func clearOnAbsentLeadIsNoOp() {
        withTempHome {
            #expect(ActiveLead.clear())
        }
    }

    @Test func corruptedLeadFileIsTreatedAsAbsent() throws {
        try withTempHome {
            // Hand-craft a malicious lead value bypassing `set`.
            let path = Paths.siftHome.appending(path: "active-lead")
            try Paths.ensure(Paths.siftHome)
            try "../../etc/passwd\n".write(to: path, atomically: true, encoding: .utf8)
            #expect(ActiveLead.get() == nil)
        }
    }

    @Test func setTrimsWhitespace() {
        withTempHome {
            #expect(ActiveLead.set("  acme-corp\n  "))
            #expect(ActiveLead.get() == "acme-corp")
        }
    }
}
