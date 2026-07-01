import XCTest
@testable import gbar

final class GitHubClientTests: XCTestCase {
    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeClient(token: String = "test-token") throws -> GitHubClient {
        let baseURL = try XCTUnwrap(URL(string: "https://api.github.com"))
        return GitHubClient(baseURL: baseURL, token: token, session: makeSession())
    }

    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    func testSearchIssuesSendsExpectedHeaders() async throws {
        let box = HeaderBox()
        MockURLProtocol.handler = { request in
            box.headers = request.allHTTPHeaderFields
            let url = try XCTUnwrap(request.url)
            let response = try XCTUnwrap(
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
            )
            let body = #"{"total_count":0,"items":[]}"#
            return (response, Data(body.utf8))
        }

        let client = try makeClient()
        _ = try await client.searchIssues("is:open is:pr")

        let headers = try XCTUnwrap(box.headers)
        XCTAssertEqual(headers["Authorization"], "Bearer test-token")
        XCTAssertEqual(headers["Accept"], "application/vnd.github+json")
        XCTAssertEqual(headers["X-GitHub-Api-Version"], "2022-11-28")
        XCTAssertEqual(headers["User-Agent"], "gbar")
    }

    func testSearchIssuesMapsUnauthorizedToHTTPError() async throws {
        MockURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            let response = try XCTUnwrap(
                HTTPURLResponse(url: url, statusCode: 401, httpVersion: nil, headerFields: nil)
            )
            return (response, Data())
        }

        let client = try makeClient()
        do {
            _ = try await client.searchIssues("is:open is:pr")
            XCTFail("Expected searchIssues to throw")
        } catch let error as GitHubClient.ClientError {
            XCTAssertEqual(error, .http(401))
        }
    }

    func testSearchIssuesDecodesItems() async throws {
        MockURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            let response = try XCTUnwrap(
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
            )
            let body = """
            {
              "total_count": 1,
              "items": [{
                "id": 1,
                "number": 42,
                "title": "Fix the thing",
                "html_url": "https://github.com/octo/repo/pull/42",
                "state": "open",
                "created_at": "2026-01-01T00:00:00Z",
                "user": { "login": "jaylann", "avatar_url": null },
                "repository_url": "https://api.github.com/repos/octo/repo",
                "pull_request": { "html_url": "https://github.com/octo/repo/pull/42", "merged_at": null },
                "draft": false
              }]
            }
            """
            return (response, Data(body.utf8))
        }

        let client = try makeClient()
        let items = try await client.searchIssues("is:open is:pr")

        XCTAssertEqual(items.count, 1)
        let first = try XCTUnwrap(items.first)
        XCTAssertEqual(first.number, 42)
        XCTAssertEqual(first.title, "Fix the thing")
    }
}

/// Reference box so the `@Sendable` handler can hand captured request headers back to the test.
private final class HeaderBox: @unchecked Sendable {
    var headers: [String: String]?
}
