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
}
