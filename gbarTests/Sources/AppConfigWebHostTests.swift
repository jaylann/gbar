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

    func testEnterprisePreservesSchemeAndPort() throws {
        // A self-hosted Enterprise instance on plain http and a non-standard port: both the
        // scheme and the port must carry through to the derived web host.
        let api = try XCTUnwrap(URL(string: "http://ghe.internal:3000/api/v3"))
        let web = AppConfig.webBaseURL(forAPI: api)
        XCTAssertEqual(web.absoluteString, "http://ghe.internal:3000")
    }

    func testUnparsableFallsBackToPublicHost() throws {
        let api = try XCTUnwrap(URL(string: "file:///local/path"))
        let web = AppConfig.webBaseURL(forAPI: api)
        XCTAssertEqual(web.absoluteString, "https://github.com")
    }

    // MARK: - GraphQL endpoint

    func testPublicGitHubGraphQLEndpoint() throws {
        let api = try XCTUnwrap(URL(string: "https://api.github.com"))
        XCTAssertEqual(AppConfig.graphQLURL(forAPI: api).absoluteString, "https://api.github.com/graphql")
    }

    func testEnterpriseGraphQLEndpoint() throws {
        let api = try XCTUnwrap(URL(string: "https://ghe.example.com/api/v3"))
        XCTAssertEqual(AppConfig.graphQLURL(forAPI: api).absoluteString, "https://ghe.example.com/api/graphql")
    }

    func testEnterpriseGraphQLPreservesSchemeAndPort() throws {
        let api = try XCTUnwrap(URL(string: "http://ghe.internal:3000/api/v3"))
        XCTAssertEqual(AppConfig.graphQLURL(forAPI: api).absoluteString, "http://ghe.internal:3000/api/graphql")
    }

    func testEnterpriseCloudDataResidencyGraphQLEndpoint() throws {
        // GHE Cloud with data residency serves GraphQL at `/graphql` on the `api.`-prefixed
        // host (no `/api` segment) — unlike GHE Server's `/api/graphql`.
        let api = try XCTUnwrap(URL(string: "https://api.acme.ghe.com"))
        XCTAssertEqual(AppConfig.graphQLURL(forAPI: api).absoluteString, "https://api.acme.ghe.com/graphql")
    }

    func testUnparsableGraphQLFallsBackToPublicEndpoint() throws {
        let api = try XCTUnwrap(URL(string: "file:///local/path"))
        XCTAssertEqual(AppConfig.graphQLURL(forAPI: api).absoluteString, "https://api.github.com/graphql")
    }
}
