import XCTest
@testable import gbar

/// Integration tests for `GitHubClient`'s write paths over the real HTTP boundary
/// (`MockURLProtocol`): the exact method, path, and JSON payload each mutation sends.
/// The read paths are covered in `GitHubClientTests`.
final class GitHubClientWritePathTests: XCTestCase {
    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeClient() throws -> GitHubClient {
        let baseURL = try XCTUnwrap(URL(string: "https://api.github.com"))
        return GitHubClient(baseURL: baseURL, token: "test-token", session: makeSession())
    }

    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    func testApprovePullRequestPostsApproveEventWithBody() async throws {
        let box = RequestBox()
        MockURLProtocol.handler = { request in
            box.capture(request)
            return try Self.emptyOK(request)
        }

        let client = try makeClient()
        try await client.approvePullRequest(repo: "octo/repo", number: 42, body: "LGTM!")

        XCTAssertEqual(box.method, "POST")
        XCTAssertEqual(box.path, "/repos/octo/repo/pulls/42/reviews")
        XCTAssertEqual(box.contentType, "application/json")
        let payload = try XCTUnwrap(box.jsonBody)
        XCTAssertEqual(payload["event"], "APPROVE")
        XCTAssertEqual(payload["body"], "LGTM!")
    }

    func testApprovePullRequestOmitsEmptyReviewBody() async throws {
        let box = RequestBox()
        MockURLProtocol.handler = { request in
            box.capture(request)
            return try Self.emptyOK(request)
        }

        let client = try makeClient()
        try await client.approvePullRequest(repo: "octo/repo", number: 42, body: "")

        let payload = try XCTUnwrap(box.jsonBody)
        XCTAssertEqual(payload, ["event": "APPROVE"])
    }

    func testMergePullRequestPutsMergeMethod() async throws {
        let box = RequestBox()
        MockURLProtocol.handler = { request in
            box.capture(request)
            return try Self.emptyOK(request)
        }

        let client = try makeClient()
        try await client.mergePullRequest(repo: "octo/repo", number: 7, method: .squash)

        XCTAssertEqual(box.method, "PUT")
        XCTAssertEqual(box.path, "/repos/octo/repo/pulls/7/merge")
        XCTAssertEqual(box.jsonBody, ["merge_method": "squash"])
    }

    func testMarkNotificationReadPatchesThreadPathWithoutBody() async throws {
        let box = RequestBox()
        MockURLProtocol.handler = { request in
            box.capture(request)
            return try Self.emptyOK(request)
        }

        let client = try makeClient()
        try await client.markNotificationRead(threadID: "12345")

        XCTAssertEqual(box.method, "PATCH")
        XCTAssertEqual(box.path, "/notifications/threads/12345")
        XCTAssertNil(box.jsonBody)
    }

    func testSearchIssuesEncodesQueryAndPageSize() async throws {
        let box = RequestBox()
        MockURLProtocol.handler = { request in
            box.capture(request)
            let url = try XCTUnwrap(request.url)
            let response = try XCTUnwrap(
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
            )
            return (response, Data(#"{"total_count":0,"items":[]}"#.utf8))
        }

        let client = try makeClient()
        _ = try await client.searchIssues("is:open is:pr review-requested:@me")

        let url = try XCTUnwrap(box.url)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = try XCTUnwrap(components.queryItems)
        XCTAssertEqual(
            items.first(where: { $0.name == "q" })?.value,
            "is:open is:pr review-requested:@me"
        )
        XCTAssertEqual(items.first(where: { $0.name == "per_page" })?.value, "50")
    }

    func testMergeFailureMapsToHTTPError() async throws {
        MockURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            let response = try XCTUnwrap(
                HTTPURLResponse(url: url, statusCode: 405, httpVersion: nil, headerFields: nil)
            )
            return (response, Data(#"{"message":"Pull Request is not mergeable"}"#.utf8))
        }

        let client = try makeClient()
        do {
            try await client.mergePullRequest(repo: "octo/repo", number: 7, method: .merge)
            XCTFail("Expected mergePullRequest to throw")
        } catch let error as GitHubClient.ClientError {
            XCTAssertEqual(error, .http(405))
        }
    }

    func testRateLimitedSearchMapsToHTTPError() async throws {
        MockURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            let response = try XCTUnwrap(HTTPURLResponse(
                url: url,
                statusCode: 403,
                httpVersion: nil,
                headerFields: ["X-RateLimit-Remaining": "0"]
            ))
            return (response, Data(#"{"message":"API rate limit exceeded"}"#.utf8))
        }

        let client = try makeClient()
        do {
            _ = try await client.searchIssues("is:open is:pr")
            XCTFail("Expected searchIssues to throw")
        } catch let error as GitHubClient.ClientError {
            XCTAssertEqual(error, .http(403))
        }
    }

    private static func emptyOK(_ request: URLRequest) throws -> (HTTPURLResponse, Data) {
        let url = try XCTUnwrap(request.url)
        let response = try XCTUnwrap(
            HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
        )
        return (response, Data())
    }
}

/// Reference box so the `@Sendable` handler can hand the captured request back to the test.
/// `URLProtocol` nils out `httpBody`, so the body is read from `httpBodyStream`.
private final class RequestBox: @unchecked Sendable {
    var method: String?
    var path: String?
    var url: URL?
    var contentType: String?
    var bodyData: Data?

    var jsonBody: [String: String]? {
        guard let bodyData else { return nil }
        return try? JSONDecoder().decode([String: String].self, from: bodyData)
    }

    func capture(_ request: URLRequest) {
        method = request.httpMethod
        url = request.url
        path = request.url?.path
        contentType = request.value(forHTTPHeaderField: "Content-Type")
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            let bufferSize = 4096
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: bufferSize)
                guard read > 0 else { break }
                data.append(buffer, count: read)
            }
            bodyData = data.isEmpty ? nil : data
        }
    }
}
