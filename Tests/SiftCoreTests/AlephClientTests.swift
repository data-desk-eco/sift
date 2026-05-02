import Foundation
import Testing
@testable import SiftCore

@Suite struct AlephClientNormalizeTests {

    @Test func appendsApiVersionWhenMissing() {
        #expect(AlephClient.normalize("https://aleph.occrp.org") == "https://aleph.occrp.org/api/2")
        #expect(AlephClient.normalize("https://aleph.example.org/") == "https://aleph.example.org/api/2")
    }

    @Test func leavesExistingApiPath() {
        #expect(AlephClient.normalize("https://aleph.occrp.org/api/2") == "https://aleph.occrp.org/api/2")
        #expect(AlephClient.normalize("https://aleph.example.org/api/v3") == "https://aleph.example.org/api/v3")
    }

    @Test func deriveServerNameStripsGenericPrefixes() {
        #expect(AlephClient.deriveServerName(from: "https://aleph.occrp.org/api/2") == "occrp")
        #expect(AlephClient.deriveServerName(from: "https://search.libraryofleaks.org/api/2") == "libraryofleaks")
        #expect(AlephClient.deriveServerName(from: "https://www.example.com") == "example")
        #expect(AlephClient.deriveServerName(from: "https://example.com") == "example")
    }
}
