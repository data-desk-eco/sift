import Foundation
import Testing
@testable import SiftCore

@Suite struct SessionNameTests {

    @Test func acceptsKebabSlugsAndTimestamps() {
        #expect(SessionName.isValid("acme-corp"))
        #expect(SessionName.isValid("wirecard-marsalek-russia"))
        #expect(SessionName.isValid("20260502-153012"))
        #expect(SessionName.isValid("subject-2"))
        #expect(SessionName.isValid("a"))
    }

    @Test func rejectsPathTraversal() {
        #expect(!SessionName.isValid(".."))
        #expect(!SessionName.isValid("../escape"))
        #expect(!SessionName.isValid("/etc/passwd"))
        #expect(!SessionName.isValid("a/b"))
    }

    @Test func rejectsDotPrefix() {
        #expect(!SessionName.isValid(".initialized"))
        #expect(!SessionName.isValid(".hidden-session"))
    }

    @Test func rejectsEmptyAndSpecialChars() {
        #expect(!SessionName.isValid(""))
        #expect(!SessionName.isValid("evil; rm -rf /"))
        #expect(!SessionName.isValid("with space"))
        #expect(!SessionName.isValid("name\nwith newline"))
        #expect(!SessionName.isValid("$(whoami)"))
    }

    @Test func validateThrowsWithSuggestion() {
        #expect(throws: SiftError.self) { try SessionName.validate("../evil") }
    }

    @Test func suggestKebabsTypicalPrompts() {
        #expect(SessionName.suggest(from: "Acme Corp Pandora Papers")
                == "acme-corp-pandora-papers")
        #expect(SessionName.suggest(from: "multi   spaces") == "multi-spaces")
        #expect(SessionName.suggest(from: "---leading-and-trailing---")
                == "leading-and-trailing")
    }

    @Test func suggestCapsAtFortyCharsWithoutTrailingHyphen() {
        // The 50-rep "abc " input would naively cap at "abc-abc-…-abc-",
        // which is exactly the case that needs trailing-hyphen cleanup
        // *after* truncation.
        let slug = SessionName.suggest(from: String(repeating: "abc ", count: 50))
        #expect(slug.count <= 40)
        #expect(!slug.hasSuffix("-"))
        #expect(!slug.hasPrefix("-"))
    }

    @Test func suggestReturnsEmptyForUnusableInput() {
        #expect(SessionName.suggest(from: "") == "")
        #expect(SessionName.suggest(from: "   ") == "")
        #expect(SessionName.suggest(from: "!!!@@@") == "")
    }
}
