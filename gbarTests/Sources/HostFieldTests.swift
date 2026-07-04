import XCTest
@testable import gbar

/// `HostField` guards the optional Enterprise base-URL override — the same cleartext-token-leak
/// guard as `WebLink`, applied at account-add time.
final class HostFieldTests: XCTestCase {
    func testValidHTTPSHostAccepted() {
        XCTAssertNil(HostField.error("https://ghe.example.com/api/v3"))
        XCTAssertEqual(HostField.url("https://ghe.example.com/api/v3")?.host, "ghe.example.com")
    }

    func testBlankIsValidDefaultHost() {
        XCTAssertNil(HostField.error(""))
        XCTAssertNil(HostField.error("   "))
        // Blank yields no override URL, so the caller falls back to the default host.
        XCTAssertNil(HostField.url(""))
    }

    func testHTTPRejectedToProtectToken() {
        XCTAssertNotNil(HostField.error("http://ghe.example.com/api/v3"))
        XCTAssertNil(HostField.url("http://ghe.example.com"))
    }

    func testSchemelessHostRejected() {
        // `URL(string:)` parses this as a relative path with no host — the bug the guard exists for.
        XCTAssertNotNil(HostField.error("ghe.corp.com"))
        XCTAssertNil(HostField.url("ghe.corp.com"))
    }
}
