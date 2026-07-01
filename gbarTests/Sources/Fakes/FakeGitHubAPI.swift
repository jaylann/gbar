import Foundation
@testable import gbar

/// Records calls made to the fake, so tests can assert on side effects the value-type fake
/// can't capture in a non-`mutating` method. `@unchecked Sendable` via a lock.
final class CallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _markedThreadIDs: [String] = []

    /// Thread IDs passed to `markNotificationRead`, in call order.
    var markedThreadIDs: [String] {
        lock.withLock { _markedThreadIDs }
    }

    func recordMarkRead(_ threadID: String) {
        lock.withLock { _markedThreadIDs.append(threadID) }
    }
}

/// A test double for `GitHubAPI`. Returns stubbed results keyed by query (falling back to
/// `defaultResult`), or throws an injected error. Value-type stubs stay `Sendable`-clean;
/// mutations are captured through the shared `CallRecorder` reference.
struct FakeGitHubAPI: GitHubAPI {
    /// Results keyed by exact query string.
    var resultsByQuery: [String: [SearchIssue]] = [:]
    /// Result returned when a query has no explicit stub.
    var defaultResult: [SearchIssue] = []
    /// Result returned from `notifications()`.
    var notificationsResult: [GitHubNotification] = []
    /// When set, every call throws this error instead of returning results.
    var error: Error?
    /// Captures side-effecting calls (e.g. mark-as-read) for assertions.
    var recorder = CallRecorder()

    func searchIssues(_ query: String) async throws -> [SearchIssue] {
        if let error {
            throw error
        }
        return resultsByQuery[query] ?? defaultResult
    }

    /// The mutation/detail endpoints aren't exercised by these tests; stub them so the fake
    /// satisfies the full `GitHubAPI` surface. Each throws so an accidental call fails loudly.
    private enum Unstubbed: Error { case notImplemented }

    func pullRequest(repo _: String, number _: Int) async throws -> PullRequestDetail {
        throw Unstubbed.notImplemented
    }

    func approvePullRequest(repo _: String, number _: Int) async throws {
        throw Unstubbed.notImplemented
    }

    func mergePullRequest(repo _: String, number _: Int, method _: MergeMethod) async throws {
        throw Unstubbed.notImplemented
    }

    func markNotificationRead(threadID: String) async throws {
        if let error {
            throw error
        }
        recorder.recordMarkRead(threadID)
    }

    func notifications() async throws -> [GitHubNotification] {
        if let error {
            throw error
        }
        return notificationsResult
    }
}

extension SearchIssue {
    /// Builds a minimal `SearchIssue` for tests by decoding a synthetic payload, so tests
    /// don't depend on the (non-public) memberwise initializer.
    static func stub(id: Int, number: Int = 1, title: String = "Stub") -> SearchIssue {
        let json = """
        {
          "id": \(id),
          "number": \(number),
          "title": "\(title)",
          "html_url": "https://github.com/octo/repo/pull/\(number)",
          "state": "open",
          "created_at": "2026-01-01T00:00:00Z",
          "user": { "login": "jaylann", "avatar_url": null },
          "repository_url": "https://api.github.com/repos/octo/repo",
          "pull_request": { "html_url": "https://github.com/octo/repo/pull/\(number)", "merged_at": null },
          "draft": false
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // Force-decoding a compile-time-known valid payload; guarded to avoid a crash.
        guard let issue = try? decoder.decode(SearchIssue.self, from: Data(json.utf8)) else {
            fatalError("SearchIssue.stub produced invalid JSON")
        }
        return issue
    }

    /// Builds `count` distinct stub issues.
    static func stubs(count: Int) -> [SearchIssue] {
        (0..<count).map { stub(id: $0, number: $0) }
    }
}

extension GitHubNotification {
    /// Builds a `GitHubNotification` for tests by decoding a synthetic payload, mirroring
    /// `SearchIssue.stub` so tests don't lean on the (non-public) memberwise initializer.
    static func stub(
        id: String,
        unread: Bool = true,
        reason: String = "review_requested",
        type: String = "PullRequest",
        repo: String = "octo/repo",
        title: String = "Stub notification"
    )
    -> GitHubNotification {
        let json = """
        {
          "id": "\(id)",
          "unread": \(unread),
          "reason": "\(reason)",
          "updated_at": "2026-01-01T00:00:00Z",
          "subject": {
            "title": "\(title)",
            "type": "\(type)",
            "url": "https://api.github.com/repos/\(repo)/pulls/1"
          },
          "repository": { "full_name": "\(repo)" }
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let notification = try? decoder.decode(GitHubNotification.self, from: Data(json.utf8)) else {
            fatalError("GitHubNotification.stub produced invalid JSON")
        }
        return notification
    }
}
