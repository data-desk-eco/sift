import Foundation
import XCTest
@testable import SiftCore

final class DeadlineTests: XCTestCase {

    func testParsesMixedUnits() throws {
        XCTAssertEqual(try Deadline.parseDuration("30m"), 1800)
        XCTAssertEqual(try Deadline.parseDuration("1h"), 3600)
        XCTAssertEqual(try Deadline.parseDuration("90s"), 90)
        XCTAssertEqual(try Deadline.parseDuration("1h30m"), 5400)
        XCTAssertEqual(try Deadline.parseDuration("1H30M"), 5400)
    }

    func testRejectsUnparseable() {
        XCTAssertThrowsError(try Deadline.parseDuration("bogus"))
        XCTAssertThrowsError(try Deadline.parseDuration(""))
        XCTAssertThrowsError(try Deadline.parseDuration("30"))
        XCTAssertThrowsError(try Deadline.parseDuration("30x"))
        XCTAssertThrowsError(try Deadline.parseDuration("30m garbage"))
    }

    func testPhaseGuidanceMatchesFraction() {
        let now = Int(Date().timeIntervalSince1970)
        XCTAssertEqual(Deadline(startTimestamp: now - 1440, endTimestamp: now + 2160).phase.name, "explore")
        XCTAssertEqual(Deadline(startTimestamp: now - 2520, endTimestamp: now + 1080).phase.name, "deepen")
        XCTAssertEqual(Deadline(startTimestamp: now - 2880, endTimestamp: now + 720).phase.name, "consolidate")
        XCTAssertEqual(Deadline(startTimestamp: now - 3420, endTimestamp: now + 180).phase.name, "wrap-up")
        XCTAssertEqual(Deadline(startTimestamp: now - 3700, endTimestamp: now - 100).phase.name, "overrun")
    }

    func testFormatRemainingPicksLargestUnit() {
        XCTAssertEqual(Deadline.formatRemaining(0), "0s")
        XCTAssertEqual(Deadline.formatRemaining(45), "45s")
        XCTAssertEqual(Deadline.formatRemaining(125), "2m 5s")
        XCTAssertEqual(Deadline.formatRemaining(3725), "1h 2m")
    }
}
