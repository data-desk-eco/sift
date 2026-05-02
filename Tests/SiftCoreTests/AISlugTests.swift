import Foundation
import Testing
@testable import SiftCore

@Suite struct AISlugTests {

    @Test func regexSlugHandlesPunctuation() {
        #expect(AISlug.regexSlug("Acme Corp Pandora Papers")
                == "acme-corp-pandora-papers")
        #expect(AISlug.regexSlug("multi   spaces") == "multi-spaces")
        #expect(AISlug.regexSlug("---leading-and-trailing---") == "leading-and-trailing")
    }

    @Test func regexSlugCapsAtFortyCharsWithoutTrailingHyphen() {
        // The 50-rep "abc " input would naively cap at "abc-abc-…-abc-",
        // which is exactly the case that needs trailing-hyphen cleanup
        // *after* truncation.
        let slug = AISlug.regexSlug(String(repeating: "abc ", count: 50))
        #expect(slug.count <= 40)
        #expect(!slug.hasSuffix("-"))
        #expect(!slug.hasPrefix("-"))
    }

    @Test func regexSlugTruncatesLongInput() {
        let slug = AISlug.regexSlug("Investigate Acme Corp In the Pandora Papers Investigation")
        #expect(slug.count <= 40)
        #expect(slug.hasPrefix("investigate-acme-corp"))
    }

    @Test func sanitizeStripsThinkBlock() {
        let raw = "<think>let me reason</think>\nacme-corp-investigation"
        #expect(AISlug.sanitize(raw) == "acme-corp-investigation")
    }

    @Test func sanitizeUsesLastNonEmptyLine() {
        let raw = "Sure, here's the slug:\n\nfinal-answer-slug"
        #expect(AISlug.sanitize(raw) == "final-answer-slug")
    }

    @Test func sanitizeStripsBackticksAndQuotes() {
        #expect(AISlug.sanitize("`some-slug`") == "some-slug")
        #expect(AISlug.sanitize("\"another-slug\"") == "another-slug")
    }
}
