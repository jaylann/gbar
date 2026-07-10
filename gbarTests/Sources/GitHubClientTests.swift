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

    func testHTTPBaseURLRejectedAsBadURL() async throws {
        // A misconfigured cleartext host must never send the bearer token over http.
        let baseURL = try XCTUnwrap(URL(string: "http://ghe.internal/api/v3"))
        let client = GitHubClient(baseURL: baseURL, token: "test-token", session: makeSession())
        do {
            _ = try await client.searchIssues("is:open")
            XCTFail("Expected an http base URL to be rejected")
        } catch let error as GitHubClient.ClientError {
            XCTAssertEqual(error, .badURL)
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

    func testSearchIssuesRequestSortsByUpdatedDescending() async throws {
        let box = HeaderBox()
        MockURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            box.path = url.absoluteString
            let response = try XCTUnwrap(
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
            )
            return (response, Data(#"{"total_count":0,"items":[]}"#.utf8))
        }

        let client = try makeClient()
        _ = try await client.searchIssues("is:open is:pr author:@me")

        let urlString = try XCTUnwrap(box.path)
        let components = try XCTUnwrap(URLComponents(string: urlString))
        let items = try XCTUnwrap(components.queryItems)
        // Sorting by recency keeps the capped fetch window deterministic across polls, so dormant
        // items can't churn in/out and re-fire notifications.
        XCTAssertEqual(items.first { $0.name == "sort" }?.value, "updated")
        XCTAssertEqual(items.first { $0.name == "order" }?.value, "desc")
        XCTAssertEqual(items.first { $0.name == "per_page" }?.value, "50")
        XCTAssertEqual(items.first { $0.name == "q" }?.value, "is:open is:pr author:@me")
    }

    func testCheckRunsDecodesEnvelope() async throws {
        let pathBox = HeaderBox()
        MockURLProtocol.handler = { request in
            pathBox.path = request.url?.path
            let url = try XCTUnwrap(request.url)
            let response = try XCTUnwrap(
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
            )
            let body = """
            {
              "total_count": 2,
              "check_runs": [
                {
                  "id": 100,
                  "name": "CI / build",
                  "status": "completed",
                  "conclusion": "success",
                  "started_at": "2026-01-01T00:00:00Z",
                  "completed_at": "2026-01-01T00:01:42Z"
                },
                {
                  "id": 101,
                  "name": "CI / lint",
                  "status": "in_progress",
                  "conclusion": null,
                  "started_at": "2026-01-01T00:00:05Z",
                  "completed_at": null
                }
              ]
            }
            """
            return (response, Data(body.utf8))
        }

        let client = try makeClient()
        let runs = try await client.checkRuns(repo: "octo/repo", ref: "deadbeef")

        XCTAssertEqual(pathBox.path, "/repos/octo/repo/commits/deadbeef/check-runs")
        XCTAssertEqual(runs.count, 2)
        let first = try XCTUnwrap(runs.first)
        XCTAssertEqual(first.id, 100)
        XCTAssertEqual(first.name, "CI / build")
        XCTAssertEqual(first.conclusion, "success")
        XCTAssertEqual(runs.last?.conclusion, nil)
    }

    func testReviewsDecodesAndHitsExpectedPath() async throws {
        let pathBox = HeaderBox()
        MockURLProtocol.handler = { request in
            pathBox.path = request.url?.path
            let url = try XCTUnwrap(request.url)
            let response = try XCTUnwrap(
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
            )
            let body = """
            [
              { "user": { "login": "jaylann", "avatar_url": null },
                "state": "APPROVED", "submitted_at": "2026-01-01T00:00:00Z" },
              { "user": { "login": "octocat", "avatar_url": null },
                "state": "COMMENTED", "submitted_at": null }
            ]
            """
            return (response, Data(body.utf8))
        }

        let client = try makeClient()
        let reviews = try await client.reviews(repo: "octo/repo", number: 42)

        XCTAssertEqual(pathBox.path, "/repos/octo/repo/pulls/42/reviews")
        XCTAssertEqual(reviews.count, 2)
        XCTAssertEqual(reviews.first?.user?.login, "jaylann")
        XCTAssertEqual(reviews.first?.state, "APPROVED")
        XCTAssertNil(reviews.last?.submittedAt)
    }

    /// Reviews come back ascending by `submitted_at`, and the gate derivation trusts the viewer's
    /// *last* review — so a multi-page PR must be walked to the end, not truncated at page 1's
    /// stale verdict.
    func testReviewsFollowsLinkHeaderToLastPage() async throws {
        let counter = PageCounter()
        MockURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            let page = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "page" }?.value ?? "1"
            counter.record(page)
            let headers = page == "1"
                ? ["Link": "<https://api.github.com/repos/octo/repo/pulls/42/reviews?page=2>; rel=\"next\""]
                : [:]
            let response = try XCTUnwrap(
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: headers)
            )
            // Page 1: an old approval. Page 2: the viewer's newer CHANGES_REQUESTED verdict.
            let body = page == "1"
                ? #"[{"user":{"login":"jaylann","avatar_url":null},"state":"APPROVED","submitted_at":"2026-01-01T00:00:00Z"}]"#
                : #"[{"user":{"login":"jaylann","avatar_url":null},"state":"CHANGES_REQUESTED","submitted_at":"2026-02-01T00:00:00Z"}]"#
            return (response, Data(body.utf8))
        }

        let client = try makeClient()
        let reviews = try await client.reviews(repo: "octo/repo", number: 42)

        XCTAssertEqual(counter.pages, ["1", "2"])
        XCTAssertEqual(reviews.count, 2)
        // The latest verdict (last page) survives — not dropped in favour of page 1's stale approval.
        XCTAssertEqual(reviews.last?.state, "CHANGES_REQUESTED")
    }

    func testReviewsStopsAtPageCap() async throws {
        let counter = PageCounter()
        MockURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            let page = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "page" }?.value ?? "1"
            counter.record(page)
            // Always advertise a next page — the client must still stop at the hard cap.
            let headers = ["Link": "<https://api.github.com/x?page=99>; rel=\"next\""]
            let response = try XCTUnwrap(
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: headers)
            )
            return (response, Data("[]".utf8))
        }

        let client = try makeClient()
        _ = try await client.reviews(repo: "octo/repo", number: 1)

        XCTAssertEqual(counter.pages.count, GitHubClient.reviewsPageCap)
    }

    /// The common case: a PR whose reviews fit on one page (no `Link: rel="next"`) costs exactly
    /// one request. Pins the per-PR cost so the pagination cap can't silently start over-fetching
    /// the 99%-case PR and multiply the hydration N+1 against GitHub's rate limit.
    func testReviewsSinglePageIssuesOneRequest() async throws {
        let counter = PageCounter()
        MockURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            let page = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "page" }?.value ?? "1"
            counter.record(page)
            // No Link header at all — a single page of reviews, the overwhelmingly common shape.
            let response = try XCTUnwrap(
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
            )
            let body = #"[{"user":{"login":"jaylann","avatar_url":null},"state":"APPROVED","submitted_at":"2026-01-01T00:00:00Z"}]"#
            return (response, Data(body.utf8))
        }

        let client = try makeClient()
        let reviews = try await client.reviews(repo: "octo/repo", number: 42)

        XCTAssertEqual(counter.pages, ["1"])
        XCTAssertEqual(reviews.count, 1)
    }

    // MARK: - Date decoding

    func testDecodesFractionalAndPlainISO8601Timestamps() async throws {
        MockURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            let response = try XCTUnwrap(
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
            )
            // One fractional-second timestamp, one plain — both must decode (a GHE version can emit
            // fractional seconds, which the old `.iso8601` strategy would reject, failing the page).
            let body = """
            [
              { "user": { "login": "a", "avatar_url": null },
                "state": "APPROVED", "submitted_at": "2026-02-01T00:00:00.123Z" },
              { "user": { "login": "b", "avatar_url": null },
                "state": "COMMENTED", "submitted_at": "2026-02-01T00:00:00Z" }
            ]
            """
            return (response, Data(body.utf8))
        }

        let client = try makeClient()
        let reviews = try await client.reviews(repo: "octo/repo", number: 1)

        XCTAssertEqual(reviews.count, 2)
        XCTAssertNotNil(reviews[0].submittedAt)
        XCTAssertNotNil(reviews[1].submittedAt)
    }

    func testInvalidTimestampSurfacesDecodingError() async throws {
        MockURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            let response = try XCTUnwrap(
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
            )
            let body = #"""
            [{ "user": { "login": "a", "avatar_url": null }, "state": "APPROVED", "submitted_at": "not-a-date" }]
            """#
            return (response, Data(body.utf8))
        }

        let client = try makeClient()
        do {
            _ = try await client.reviews(repo: "octo/repo", number: 1)
            XCTFail("Expected a malformed timestamp to throw a DecodingError")
        } catch is DecodingError {}
    }

    // The reviews path proves fractional seconds decode, but the gate/list paths carry their date
    // on *required* (non-optional) fields — a parse failure there fails the whole page, not one row.
    // GHE can emit fractional seconds, so exercise fractional through each required field: a throw
    // here is a hard regression (the old `.iso8601` strategy would reject fractional and blank the
    // section). These decode failures on the hydration paths are also swallowed at runtime
    // (`try?`), so only a unit test can catch them.

    func testNotificationsDecodeFractionalTimestamp() async throws {
        MockURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            let response = try XCTUnwrap(
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
            )
            let body = """
            [{
              "id": "1", "unread": true, "reason": "review_requested",
              "updated_at": "2026-02-01T00:00:00.123Z",
              "subject": { "title": "PR", "type": "PullRequest", "url": null },
              "repository": { "full_name": "octo/repo" }
            }]
            """
            return (response, Data(body.utf8))
        }

        let client = try makeClient()
        let notifications = try await client.notifications()
        XCTAssertEqual(notifications.count, 1)
        XCTAssertEqual(notifications.first?.subject.title, "PR")
    }

    func testWorkflowRunsDecodeFractionalTimestamps() async throws {
        MockURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            let response = try XCTUnwrap(
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
            )
            let body = """
            {
              "total_count": 1,
              "workflow_runs": [{
                "id": 500, "name": "CI", "display_title": "t", "head_branch": "stage",
                "event": "push", "status": "completed", "conclusion": "success",
                "html_url": "https://github.com/octo/repo/actions/runs/500", "run_number": 12,
                "created_at": "2026-01-01T00:00:00.5Z",
                "updated_at": "2026-01-01T00:01:42.250Z",
                "run_started_at": "2026-01-01T00:00:00.5Z"
              }]
            }
            """
            return (response, Data(body.utf8))
        }

        let client = try makeClient()
        let runs = try await client.workflowRuns(repo: "octo/repo")
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs.first?.id, 500)
    }

    func testReleasesDecodeFractionalTimestamp() async throws {
        MockURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            let response = try XCTUnwrap(
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
            )
            let body = """
            [{
              "id": 900, "tag_name": "v1.2.0", "name": "r",
              "html_url": "https://github.com/octo/repo/releases/tag/v1.2.0",
              "published_at": "2026-01-01T00:00:00.001Z",
              "created_at": "2026-01-01T00:00:00.001Z",
              "draft": false, "prerelease": false,
              "author": { "login": "jaylann", "avatar_url": null }
            }]
            """
            return (response, Data(body.utf8))
        }

        let client = try makeClient()
        let releases = try await client.releases(repo: "octo/repo")
        XCTAssertEqual(releases.count, 1)
        XCTAssertEqual(releases.first?.tagName, "v1.2.0")
    }

    func testSearchIssuesDecodeFractionalTimestamp() async throws {
        MockURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            let response = try XCTUnwrap(
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
            )
            let body = """
            {
              "total_count": 1,
              "items": [{
                "id": 1, "number": 42, "title": "t",
                "html_url": "https://github.com/octo/repo/pull/42", "state": "open",
                "created_at": "2026-01-01T00:00:00.42Z",
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
        XCTAssertEqual(items.first?.number, 42)
    }

    func testPullRequestDecodesFractionalTimestamps() async throws {
        MockURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            let response = try XCTUnwrap(
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
            )
            let body = """
            {
              "id": 42, "number": 42, "title": "PR", "state": "open",
              "html_url": "https://github.com/octo/repo/pull/42", "merged": false,
              "mergeable": true, "mergeable_state": "clean", "draft": false,
              "user": { "login": "jaylann", "avatar_url": null },
              "created_at": "2026-01-01T00:00:00.999Z",
              "updated_at": "2026-01-01T00:00:00.999Z",
              "head": { "sha": "abc", "ref": "feature" }
            }
            """
            return (response, Data(body.utf8))
        }

        let client = try makeClient()
        let detail = try await client.pullRequest(repo: "octo/repo", number: 42)
        XCTAssertEqual(detail.number, 42)
    }

    // MARK: - Rate limiting

    /// A primary-limit 403 (`X-RateLimit-Remaining: 0`) is surfaced as `.rateLimited` carrying the
    /// reset time, not a generic `.http(403)`, so the store can back off instead of hammering.
    func testExhaustedPrimaryLimitMapsToRateLimited() async throws {
        let reset = Date().addingTimeInterval(120)
        MockURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            let headers = [
                "X-RateLimit-Remaining": "0",
                "X-RateLimit-Reset": String(Int(reset.timeIntervalSince1970)),
            ]
            let response = try XCTUnwrap(
                HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil, headerFields: headers)
            )
            return (response, Data())
        }

        let client = try makeClient()
        do {
            _ = try await client.searchIssues("is:open")
            XCTFail("Expected rate-limit error")
        } catch let GitHubClient.ClientError.rateLimited(until) {
            let until = try XCTUnwrap(until)
            XCTAssertEqual(until.timeIntervalSince1970, reset.timeIntervalSince1970, accuracy: 1)
        }
    }

    /// A secondary-limit 429 with `Retry-After` maps to `.rateLimited`, with the reset derived from
    /// the relative header.
    func testSecondaryLimitWithRetryAfterMapsToRateLimited() async throws {
        MockURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: url,
                    statusCode: 429,
                    httpVersion: nil,
                    headerFields: ["Retry-After": "30"]
                )
            )
            return (response, Data())
        }

        let client = try makeClient()
        do {
            _ = try await client.notifications()
            XCTFail("Expected rate-limit error")
        } catch let GitHubClient.ClientError.rateLimited(until) {
            let until = try XCTUnwrap(until)
            XCTAssertEqual(until.timeIntervalSinceNow, 30, accuracy: 3)
        }
    }

    /// A permissions 403 (SSO/scope) with no rate-limit signal stays `.http(403)` — it is not a
    /// rate limit and must not trigger a backoff.
    func testForbiddenWithoutRateLimitHeadersStaysHTTP403() async throws {
        MockURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: url,
                    statusCode: 403,
                    httpVersion: nil,
                    headerFields: ["X-RateLimit-Remaining": "42"]
                )
            )
            return (response, Data())
        }

        let client = try makeClient()
        do {
            _ = try await client.searchIssues("is:open")
            XCTFail("Expected http error")
        } catch let error as GitHubClient.ClientError {
            XCTAssertEqual(error, .http(403))
        }
    }

    /// A secondary-limit 403 that carries only `X-RateLimit-Reset` (no `Remaining: 0`, no
    /// `Retry-After`) still maps to `.rateLimited`, with the reset read from that epoch header.
    func testForbiddenWithResetHeaderMapsToRateLimited() async throws {
        let reset = Date().addingTimeInterval(90)
        MockURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            let headers = ["X-RateLimit-Reset": String(Int(reset.timeIntervalSince1970))]
            let response = try XCTUnwrap(
                HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil, headerFields: headers)
            )
            return (response, Data())
        }

        let client = try makeClient()
        do {
            _ = try await client.searchIssues("is:open")
            XCTFail("Expected rate-limit error")
        } catch let GitHubClient.ClientError.rateLimited(until) {
            let until = try XCTUnwrap(until)
            XCTAssertEqual(until.timeIntervalSince1970, reset.timeIntervalSince1970, accuracy: 1)
        }
    }

    /// A secondary/abuse-limit 403 identified only by its body (no rate-limit headers at all) still
    /// maps to `.rateLimited` so the store backs off; `until` is nil (store applies its default).
    func testForbiddenWithSecondaryRateLimitBodyMapsToRateLimited() async throws {
        MockURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            let response = try XCTUnwrap(
                HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil, headerFields: nil)
            )
            let body = #"{"message":"You have exceeded a secondary rate limit. Please wait a few minutes."}"#
            return (response, Data(body.utf8))
        }

        let client = try makeClient()
        do {
            _ = try await client.searchIssues("is:open")
            XCTFail("Expected rate-limit error")
        } catch let GitHubClient.ClientError.rateLimited(until) {
            XCTAssertNil(until)
        }
    }

    /// A literal `+` in a saved search (e.g. `c++`) must reach `/search/issues` as `%2B`, not a
    /// space — `URLComponents` leaves `+` unescaped, so the client re-encodes it.
    func testSearchQueryEncodesPlusAsPercent2B() async throws {
        let box = HeaderBox()
        MockURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            box.path = url.absoluteString
            let response = try XCTUnwrap(
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
            )
            return (response, Data(#"{"total_count":0,"items":[]}"#.utf8))
        }

        let client = try makeClient()
        _ = try await client.searchIssues("c++ in:title")

        let urlString = try XCTUnwrap(box.path)
        XCTAssertTrue(urlString.contains("c%2B%2B"), "expected + encoded as %2B, got: \(urlString)")
        XCTAssertFalse(urlString.contains("c++"))
    }

    func testMarkAllNotificationsReadHitsExpectedPath() async throws {
        let box = HeaderBox()
        MockURLProtocol.handler = { request in
            box.path = request.url?.path
            box.method = request.httpMethod
            box.headers = request.allHTTPHeaderFields
            let url = try XCTUnwrap(request.url)
            let response = try XCTUnwrap(
                HTTPURLResponse(url: url, statusCode: 202, httpVersion: nil, headerFields: nil)
            )
            return (response, Data())
        }

        let client = try makeClient()
        try await client.markAllNotificationsRead()

        XCTAssertEqual(box.path, "/notifications")
        XCTAssertEqual(box.method, "PUT")
        let headers = try XCTUnwrap(box.headers)
        XCTAssertEqual(headers["Authorization"], "Bearer test-token")
        XCTAssertEqual(headers["X-GitHub-Api-Version"], "2022-11-28")
    }

    func testRepositoryDecodesPermissions() async throws {
        let pathBox = HeaderBox()
        MockURLProtocol.handler = { request in
            pathBox.path = request.url?.path
            let url = try XCTUnwrap(request.url)
            let response = try XCTUnwrap(
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
            )
            let body = """
            { "permissions": { "admin": false, "maintain": true, "push": true, "pull": true } }
            """
            return (response, Data(body.utf8))
        }

        let client = try makeClient()
        let info = try await client.repository(repo: "octo/repo")

        XCTAssertEqual(pathBox.path, "/repos/octo/repo")
        XCTAssertEqual(info.permissions?.push, true)
        XCTAssertEqual(info.permissions?.maintain, true)
        XCTAssertEqual(info.permissions?.admin, false)
    }

    // MARK: - Starred (pagination)

    func testStarredReposFollowsLinkHeaderAcrossPages() async throws {
        let counter = PageCounter()
        MockURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            let page = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "page" }?.value ?? "1"
            counter.record(page)
            // Two pages: page 1 advertises a next link, page 2 doesn't.
            let hasNext = page == "1"
            let headers = hasNext
                ? ["Link": "<https://api.github.com/user/starred?page=2>; rel=\"next\""]
                : [:]
            let response = try XCTUnwrap(
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: headers)
            )
            let body = page == "1"
                ? #"[{"full_name":"octo/one"},{"full_name":"octo/two"}]"#
                : #"[{"full_name":"octo/three"}]"#
            return (response, Data(body.utf8))
        }

        let client = try makeClient()
        let slugs = try await client.starredRepos()

        // Walked exactly two pages (stopped when the Link header dropped rel="next").
        XCTAssertEqual(counter.pages, ["1", "2"])
        XCTAssertEqual(slugs, ["octo/one", "octo/two", "octo/three"])
    }

    func testStarredReposStopsWithoutLinkHeader() async throws {
        let counter = PageCounter()
        MockURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            let page = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "page" }?.value ?? "1"
            counter.record(page)
            let response = try XCTUnwrap(
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
            )
            return (response, Data(#"[{"full_name":"octo/only"}]"#.utf8))
        }

        let client = try makeClient()
        let slugs = try await client.starredRepos()

        // No Link header → single request, no needless second page.
        XCTAssertEqual(counter.pages, ["1"])
        XCTAssertEqual(slugs, ["octo/only"])
    }

    // MARK: - Actions runs / Releases

    func testWorkflowRunsDecodesEnvelope() async throws {
        let pathBox = HeaderBox()
        MockURLProtocol.handler = { request in
            pathBox.path = request.url?.path
            let url = try XCTUnwrap(request.url)
            let response = try XCTUnwrap(
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
            )
            let body = """
            {
              "total_count": 1,
              "workflow_runs": [{
                "id": 500,
                "name": "CI",
                "display_title": "Fix the thing",
                "head_branch": "stage",
                "event": "push",
                "status": "completed",
                "conclusion": "success",
                "html_url": "https://github.com/octo/repo/actions/runs/500",
                "run_number": 12,
                "created_at": "2026-01-01T00:00:00Z",
                "updated_at": "2026-01-01T00:01:42Z",
                "run_started_at": "2026-01-01T00:00:00Z"
              }]
            }
            """
            return (response, Data(body.utf8))
        }

        let client = try makeClient()
        let runs = try await client.workflowRuns(repo: "octo/repo")

        XCTAssertEqual(pathBox.path, "/repos/octo/repo/actions/runs")
        XCTAssertEqual(runs.count, 1)
        let first = try XCTUnwrap(runs.first)
        XCTAssertEqual(first.id, 500)
        XCTAssertEqual(first.displayTitle, "Fix the thing")
        XCTAssertEqual(first.event, "push")
        XCTAssertEqual(first.ciStatus, .success)
    }

    func testReleasesDecodesArray() async throws {
        let pathBox = HeaderBox()
        MockURLProtocol.handler = { request in
            pathBox.path = request.url?.path
            let url = try XCTUnwrap(request.url)
            let response = try XCTUnwrap(
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
            )
            let body = """
            [{
              "id": 900,
              "tag_name": "v1.2.0",
              "name": "Inbox & quick actions",
              "html_url": "https://github.com/octo/repo/releases/tag/v1.2.0",
              "published_at": "2026-01-01T00:00:00Z",
              "created_at": "2026-01-01T00:00:00Z",
              "draft": false,
              "prerelease": false,
              "author": { "login": "jaylann", "avatar_url": null }
            }]
            """
            return (response, Data(body.utf8))
        }

        let client = try makeClient()
        let releases = try await client.releases(repo: "octo/repo")

        XCTAssertEqual(pathBox.path, "/repos/octo/repo/releases")
        XCTAssertEqual(releases.count, 1)
        let first = try XCTUnwrap(releases.first)
        XCTAssertEqual(first.tagName, "v1.2.0")
        XCTAssertEqual(first.name, "Inbox & quick actions")
        XCTAssertFalse(first.prerelease)
    }

    /// GitHub sends `Cache-Control: private, max-age=60` on PR endpoints, so the default cache
    /// policy would serve a stale body right after an approve/merge (the "Merge won't unlock" bug).
    /// Requests revalidate with the origin instead: a changed resource returns a fresh 200 (the PR
    /// reflects at once) while an unchanged one returns a rate-limit-free 304, so an idle inbox's
    /// re-poll stops burning the hourly budget.
    func testRequestsRevalidateWithOrigin() async throws {
        let box = HeaderBox()
        MockURLProtocol.handler = { request in
            box.cachePolicy = request.cachePolicy
            let url = try XCTUnwrap(request.url)
            let response = try XCTUnwrap(HTTPURLResponse(
                url: url, statusCode: 200,
                httpVersion: nil, headerFields: ["Cache-Control": "private, max-age=60"]
            ))
            let body = """
            {
              "id": 42, "number": 42, "title": "PR", "state": "open",
              "html_url": "https://github.com/octo/repo/pull/42", "merged": false,
              "mergeable": true, "mergeable_state": "clean", "draft": false,
              "user": { "login": "jaylann", "avatar_url": null },
              "created_at": "2026-01-01T00:00:00Z", "updated_at": "2026-01-01T00:00:00Z",
              "head": { "sha": "abc", "ref": "feature" }
            }
            """
            return (response, Data(body.utf8))
        }

        let client = try makeClient()
        _ = try await client.pullRequest(repo: "octo/repo", number: 42)

        XCTAssertEqual(box.cachePolicy, .reloadRevalidatingCacheData)
    }
}

/// Records the `page` query values a paginated request walks through, in order.
private final class PageCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _pages: [String] = []
    var pages: [String] {
        lock.withLock { _pages }
    }

    func record(_ page: String) {
        lock.withLock { _pages.append(page) }
    }
}

/// Reference box so the `@Sendable` handler can hand captured request headers back to the test.
private final class HeaderBox: @unchecked Sendable {
    var headers: [String: String]?
    var path: String?
    var method: String?
    var cachePolicy: URLRequest.CachePolicy?
}
