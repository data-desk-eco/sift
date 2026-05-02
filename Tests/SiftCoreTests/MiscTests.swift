import Foundation
import Testing
@testable import SiftCore

@Suite struct ShellQuoteTests {

    @Test func passesThroughBareTokens() {
        #expect(Sift.shellQuote("simple") == "simple")
        #expect(Sift.shellQuote("path/with-dashes") == "path/with-dashes")
        #expect(Sift.shellQuote("file.ext") == "file.ext")
        #expect(Sift.shellQuote("under_score") == "under_score")
    }

    @Test func quotesValuesWithSpaces() {
        #expect(Sift.shellQuote("with space") == "'with space'")
        #expect(Sift.shellQuote("a b c") == "'a b c'")
    }

    @Test func escapesEmbeddedSingleQuotes() {
        // POSIX trick: close the quote, escape the apostrophe, re-open.
        #expect(Sift.shellQuote("it's") == #"'it'\''s'"#)
    }

    @Test func quotesShellMetacharacters() {
        #expect(Sift.shellQuote("$(whoami)") == "'$(whoami)'")
        #expect(Sift.shellQuote("a;b") == "'a;b'")
        #expect(Sift.shellQuote("a&b") == "'a&b'")
        #expect(Sift.shellQuote("a|b") == "'a|b'")
    }

    @Test func handlesEmptyString() {
        #expect(Sift.shellQuote("") == "''")
    }
}

@Suite struct SiftErrorTests {

    @Test func descriptionWithoutSuggestion() {
        let err = SiftError("something broke")
        #expect(err.errorDescription == "something broke")
    }

    @Test func descriptionIncludesSuggestion() {
        let err = SiftError("config missing", suggestion: "run sift init")
        #expect(err.errorDescription == "config missing\n  → run sift init")
    }
}
