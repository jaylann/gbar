import XCTest
@testable import gbar

final class AppConfigWebHostTests: XCTestCase {
    func testPublicGitHubMapsToWebHost() throws {
        let api = try XCTUnwrap(URL(string: "https://api.github.com"))
        let web = AppConfig.webBaseURL(forAPI: api)
        XCTAssertEqual(web.absoluteString, "https://github.com")
    }

    func testEnterpriseStripsAPIPath() throws {
        let api = try XCTUnwrap(URL(string: "https://ghe.example.com/api/v3"))
        let web = AppConfig.webBaseURL(forAPI: api)
        XCTAssertEqual(web.absoluteString, "https://ghe.example.com")
    }

    func testEnterprisePreservesNonStandardPort() throws {
        let api = try XCTUnwrap(URL(string: "https://ghe.example.com:8443/api/v3"))
        let web = AppConfig.webBaseURL(forAPI: api)
        XCTAssertEqual(web.absoluteString, "https://ghe.example.com:8443")
    }

    func testUnparsableFallsBackToPublicHost() throws {
        let api = try XCTUnwrap(URL(string: "file:///local/path"))
        let web = AppConfig.webBaseURL(forAPI: api)
        XCTAssertEqual(web.absoluteString, "https://github.com")
    }
}
