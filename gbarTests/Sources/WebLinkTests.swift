import XCTest
@testable import gbar

/// `WebLink` is the scheme allowlist guarding every URL opened from a (semi-trusted) GitHub host.
final class WebLinkTests: XCTestCase {
    func testAllowsHTTPAndHTTPS() {
        XCTAssertEqual(
            WebLink.parse("https://github.com/octo/repo/pull/1")?.absoluteString,
            "https://github.com/octo/repo/pull/1"
        )
        XCTAssertNotNil(WebLink.parse("http://ghe.internal/octo/repo"))
    }

    func testRejectsNonWebSchemes() {
        XCTAssertNil(WebLink.parse("file:///etc/passwd"))
        XCTAssertNil(WebLink.parse("javascript:alert(1)"))
        XCTAssertNil(WebLink.parse("ftp://example.com/x"))
        XCTAssertNil(WebLink.parse("custom-scheme://do-something"))
    }

    func testRejectsNilAndUnparseable() {
        XCTAssertNil(WebLink.parse(nil))
        XCTAssertNil(WebLink.parse(""))
    }

    func testSanitizePassesThroughOnlyWebURLs() {
        XCTAssertNotNil(WebLink.sanitize(URL(string: "https://github.com")))
        XCTAssertNil(WebLink.sanitize(URL(fileURLWithPath: "/tmp/x")))
        XCTAssertNil(WebLink.sanitize(nil))
    }
}
