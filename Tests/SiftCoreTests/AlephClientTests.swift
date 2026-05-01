import Foundation
import XCTest
@testable import SiftCore

final class AlephClientTests: XCTestCase {

    func testAppendsApiVersionWhenMissing() {
        XCTAssertEqual(AlephClient.normalize("https://aleph.occrp.org"), "https://aleph.occrp.org/api/2")
        XCTAssertEqual(AlephClient.normalize("https://aleph.example.org/"), "https://aleph.example.org/api/2")
    }

    func testLeavesExistingApiPath() {
        XCTAssertEqual(AlephClient.normalize("https://aleph.occrp.org/api/2"), "https://aleph.occrp.org/api/2")
        XCTAssertEqual(AlephClient.normalize("https://aleph.example.org/api/v3"), "https://aleph.example.org/api/v3")
    }

    func testDeriveServerNameStripsGenericPrefixes() {
        XCTAssertEqual(AlephClient.deriveServerName(from: "https://aleph.occrp.org/api/2"), "occrp")
        XCTAssertEqual(AlephClient.deriveServerName(from: "https://search.libraryofleaks.org/api/2"), "libraryofleaks")
        XCTAssertEqual(AlephClient.deriveServerName(from: "https://www.example.com"), "example")
        XCTAssertEqual(AlephClient.deriveServerName(from: "https://example.com"), "example")
    }
}
