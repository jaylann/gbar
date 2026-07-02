import XCTest
@testable import gbar

/// Pins the Codable wire contract of the REST DTOs against representative GitHub payloads,
/// including tolerance for the optional fields GitHub omits or nulls. Uses the same
/// `.iso8601` date strategy as `GitHubClient`.
final class GitHubModelsDecodingTests: XCTestCase {
    private func decode<T: Decodable>(_: T.Type, _ json: String) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: Data(json.utf8))
    }

    func testSearchIssueDecodesWithMinimalOptionalFields() throws {
        // No user, no draft, no pull_request — the bare issue shape.
        let issue = try decode(SearchIssue.self, """
        {
          "id": 7,
          "number": 12,
          "title": "Crash on launch",
          "html_url": "https://github.com/octo/repo/issues/12",
          "state": "open",
          "created_at": "2026-01-01T00:00:00Z",
          "repository_url": "https://api.github.com/repos/octo/repo"
        }
        """)

        XCTAssertNil(issue.user)
        XCTAssertNil(issue.draft)
        XCTAssertNil(issue.updatedAt) // absent in payload → nil, gates fall back to createdAt
        XCTAssertFalse(issue.isPullRequest)
        XCTAssertEqual(issue.repositorySlug, "octo/repo")
    }

    func testSearchIssueDecodesUpdatedAt() throws {
        let issue = try decode(SearchIssue.self, """
        {
          "id": 8,
          "number": 13,
          "title": "Recently touched",
          "html_url": "https://github.com/octo/repo/pull/13",
          "state": "open",
          "created_at": "2026-01-01T00:00:00Z",
          "updated_at": "2026-06-15T12:00:00Z",
          "repository_url": "https://api.github.com/repos/octo/repo"
        }
        """)

        XCTAssertEqual(issue.updatedAt, ISO8601DateFormatter().date(from: "2026-06-15T12:00:00Z"))
    }

    func testPullRequestDetailDecodesFullPayload() throws {
        let detail = try decode(PullRequestDetail.self, """
        {
          "id": 100,
          "number": 42,
          "title": "Add feature",
          "state": "open",
          "html_url": "https://github.com/octo/repo/pull/42",
          "merged": false,
          "mergeable": true,
          "mergeable_state": "clean",
          "draft": false,
          "user": { "login": "jaylann", "avatar_url": "https://avatars.example/1" },
          "created_at": "2026-01-01T00:00:00Z",
          "updated_at": "2026-01-02T00:00:00Z",
          "head": { "sha": "deadbeef", "ref": "feature/x" }
        }
        """)

        XCTAssertEqual(detail.mergeableState, "clean")
        XCTAssertEqual(detail.head.sha, "deadbeef")
        XCTAssertEqual(detail.head.ref, "feature/x")
        XCTAssertEqual(detail.user?.login, "jaylann")
    }

    func testPullRequestDetailToleratesNullMergeFields() throws {
        // GitHub returns mergeable: null while it recomputes merge state.
        let detail = try decode(PullRequestDetail.self, """
        {
          "id": 100,
          "number": 42,
          "title": "Add feature",
          "state": "open",
          "html_url": "https://github.com/octo/repo/pull/42",
          "merged": null,
          "mergeable": null,
          "mergeable_state": null,
          "created_at": "2026-01-01T00:00:00Z",
          "head": { "sha": "deadbeef", "ref": "feature/x" }
        }
        """)

        XCTAssertNil(detail.mergeable)
        XCTAssertNil(detail.mergeableState)
        XCTAssertNil(detail.updatedAt)
        XCTAssertNil(detail.draft)
    }

    func testPullRequestReviewDecodesWithoutUser() throws {
        // Deleted accounts come back as user: null; the review still counts.
        let review = try decode(PullRequestReview.self, """
        { "user": null, "state": "APPROVED", "submitted_at": "2026-01-01T00:00:00Z" }
        """)

        XCTAssertNil(review.user)
        XCTAssertEqual(review.state, "APPROVED")
    }

    func testRepositoryInfoOmittedMergeFlagsDefaultToAllowed() throws {
        // A token without admin scope gets no allow_* flags — no method may be hidden.
        let info = try decode(RepositoryInfo.self, "{}")

        XCTAssertNil(info.permissions)
        XCTAssertEqual(info.allowedMergeMethods, [.merge, .squash, .rebase])
    }

    func testRepositoryInfoRespectsDisabledMergeMethods() throws {
        let info = try decode(RepositoryInfo.self, """
        {
          "permissions": { "push": true, "admin": false },
          "allow_merge_commit": false,
          "allow_squash_merge": true,
          "allow_rebase_merge": false
        }
        """)

        XCTAssertEqual(info.allowedMergeMethods, [.squash])
        XCTAssertEqual(info.permissions?.push, true)
        XCTAssertNil(info.permissions?.maintain)
    }

    func testCheckRunsResponseDecodesEnvelope() throws {
        let response = try decode(CheckRunsResponse.self, """
        {
          "total_count": 1,
          "check_runs": [{
            "id": 5,
            "name": "CI / build",
            "status": "in_progress",
            "conclusion": null,
            "started_at": "2026-01-01T00:00:00Z",
            "completed_at": null
          }]
        }
        """)

        XCTAssertEqual(response.checkRuns.count, 1)
        let run = try XCTUnwrap(response.checkRuns.first)
        XCTAssertEqual(run.status, "in_progress")
        XCTAssertNil(run.conclusion)
        XCTAssertNil(run.completedAt)
    }

    func testWorkflowRunsResponseDecodesEnvelope() throws {
        let response = try decode(WorkflowRunsResponse.self, """
        {
          "total_count": 1,
          "workflow_runs": [{
            "id": 900,
            "name": "Release",
            "display_title": null,
            "head_branch": null,
            "event": "schedule",
            "status": "completed",
            "conclusion": "success",
            "html_url": "https://github.com/octo/repo/actions/runs/900",
            "run_number": 17,
            "created_at": "2026-01-01T00:00:00Z",
            "updated_at": "2026-01-01T00:05:00Z"
          }]
        }
        """)

        let run = try XCTUnwrap(response.workflowRuns.first)
        XCTAssertNil(run.displayTitle)
        XCTAssertNil(run.headBranch)
        XCTAssertNil(run.runStartedAt)
        XCTAssertEqual(run.runNumber, 17)
    }

    func testReleaseDecodesDraftWithNullFields() throws {
        let release = try decode(Release.self, """
        {
          "id": 1,
          "tag_name": "v0.9.0",
          "name": null,
          "html_url": "https://github.com/octo/repo/releases/tag/v0.9.0",
          "published_at": null,
          "created_at": "2026-01-01T00:00:00Z",
          "draft": true,
          "prerelease": false,
          "author": null
        }
        """)

        XCTAssertNil(release.name)
        XCTAssertNil(release.publishedAt)
        XCTAssertNil(release.author)
        XCTAssertTrue(release.draft)
    }

    func testGitHubNotificationDecodesSubjectWithoutURL() throws {
        // Discussions and some subject types have no API URL.
        let notification = try decode(GitHubNotification.self, """
        {
          "id": "123",
          "unread": true,
          "reason": "mention",
          "updated_at": "2026-01-01T00:00:00Z",
          "subject": { "title": "Roadmap", "type": "Discussion", "url": null },
          "repository": { "full_name": "octo/repo" }
        }
        """)

        XCTAssertNil(notification.subject.url)
        XCTAssertEqual(notification.subject.type, "Discussion")
        XCTAssertEqual(notification.repository.fullName, "octo/repo")
    }

    func testStarredRepoDecodesSlug() throws {
        let repo = try decode(StarredRepo.self, #"{"full_name": "octo/repo"}"#)
        XCTAssertEqual(repo.fullName, "octo/repo")
    }
}
