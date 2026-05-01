import Foundation
import XCTest
@testable import SiftCore

final class AISlugTests: XCTestCase {

    func testRegexSlugHandlesPunctuation() {
        XCTAssertEqual(
            AISlug.regexSlug("Investigate Acme Corp! In the Pandora Papers"),
            "investigate-acme-corp-in-the-pandora-papers"
        )
        XCTAssertEqual(AISlug.regexSlug("multi   spaces"), "multi-spaces")
        XCTAssertEqual(AISlug.regexSlug("---leading-and-trailing---"), "leading-and-trailing")
    }

    func testRegexSlugCapsAtFortyChars() {
        let big = String(repeating: "abc ", count: 50)
        let slug = AISlug.regexSlug(big)
        XCTAssertLessThanOrEqual(slug.count, 40)
        XCTAssertFalse(slug.hasSuffix("-"))
    }

    func testSanitizeStripsThinkBlock() {
        let raw = "<think>let me reason</think>\nacme-corp-investigation"
        XCTAssertEqual(AISlug.sanitize(raw), "acme-corp-investigation")
    }

    func testSanitizeUsesLastNonEmptyLine() {
        let raw = "Sure, here's the slug:\n\nfinal-answer-slug"
        XCTAssertEqual(AISlug.sanitize(raw), "final-answer-slug")
    }

    func testSanitizeStripsBackticksAndQuotes() {
        XCTAssertEqual(AISlug.sanitize("`some-slug`"), "some-slug")
        XCTAssertEqual(AISlug.sanitize("\"another-slug\""), "another-slug")
    }
}
