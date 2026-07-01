import XCTest
@testable import gbar

final class SearchIssueTests: XCTestCase {
    func testDecodesPullRequestAndRepoSlug() throws {
        let json = """
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
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let response = try decoder.decode(SearchResponse.self, from: Data(json.utf8))
        let item = try XCTUnwrap(response.items.first)

        XCTAssertTrue(item.isPullRequest)
        XCTAssertEqual(item.repositorySlug, "octo/repo")
        XCTAssertEqual(item.number, 42)
        XCTAssertEqual(item.user?.login, "jaylann")
    }

    func testIssueIsNotPullRequest() throws {
        let json = """
        {
          "total_count": 1,
          "items": [{
            "id": 2,
            "number": 7,
            "title": "A bug",
            "html_url": "https://github.com/octo/repo/issues/7",
            "state": "open",
            "created_at": "2026-01-01T00:00:00Z",
            "user": { "login": "jaylann", "avatar_url": null },
            "repository_url": "https://api.github.com/repos/octo/repo"
          }]
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let response = try decoder.decode(SearchResponse.self, from: Data(json.utf8))
        let item = try XCTUnwrap(response.items.first)

        XCTAssertFalse(item.isPullRequest)
        XCTAssertEqual(item.repositorySlug, "octo/repo")
    }
}
