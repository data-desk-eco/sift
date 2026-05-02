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
}
