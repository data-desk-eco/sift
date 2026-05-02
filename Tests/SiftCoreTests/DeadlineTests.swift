import Foundation
import Testing
@testable import SiftCore

@Suite struct DeadlineTests {

    @Test func parsesMixedUnits() throws {
        #expect(try Deadline.parseDuration("30m") == 1800)
        #expect(try Deadline.parseDuration("1h") == 3600)
        #expect(try Deadline.parseDuration("90s") == 90)
        #expect(try Deadline.parseDuration("1h30m") == 5400)
        #expect(try Deadline.parseDuration("1H30M") == 5400)
    }

    @Test func rejectsUnparseable() {
        #expect(throws: SiftError.self) { try Deadline.parseDuration("bogus") }
        #expect(throws: SiftError.self) { try Deadline.parseDuration("") }
        #expect(throws: SiftError.self) { try Deadline.parseDuration("30") }
        #expect(throws: SiftError.self) { try Deadline.parseDuration("30x") }
        #expect(throws: SiftError.self) { try Deadline.parseDuration("30m garbage") }
    }

    @Test func phaseGuidanceMatchesFraction() {
        let now = Int(Date().timeIntervalSince1970)
        #expect(Deadline(startTimestamp: now - 1440, endTimestamp: now + 2160).phase.name == "explore")
        #expect(Deadline(startTimestamp: now - 2520, endTimestamp: now + 1080).phase.name == "deepen")
        #expect(Deadline(startTimestamp: now - 2880, endTimestamp: now + 720).phase.name == "consolidate")
        #expect(Deadline(startTimestamp: now - 3420, endTimestamp: now + 180).phase.name == "wrap-up")
        #expect(Deadline(startTimestamp: now - 3700, endTimestamp: now - 100).phase.name == "overrun")
    }

    @Test func formatRemainingPicksLargestUnit() {
        #expect(Deadline.formatRemaining(0) == "0s")
        #expect(Deadline.formatRemaining(45) == "45s")
        #expect(Deadline.formatRemaining(125) == "2m 5s")
        #expect(Deadline.formatRemaining(3725) == "1h 2m")
    }
}
