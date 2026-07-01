import Foundation
@testable import gbar

/// Thread-safe recorder for the side-effecting calls a `FakeGitHubAPI` receives
/// (mark-as-read, approve, merge), so tests can assert on them even though the value-type,
/// `let`-held fake can't capture calls in a non-`mutating` method. `@unchecked Sendable` via a lock.
final class CallRecorder: @unchecked Sendable {
    struct Approve: Equatable {
        let repo: String
        let number: Int
    }

    struct Merge: Equatable {
        let repo: String
        let number: Int
        let method: MergeMethod
    }

    private let lock = NSLock()
    private var _markedThreadIDs: [String] = []
    private var _approvals: [Approve] = []
    private var _merges: [Merge] = []

    /// Thread IDs passed to `markNotificationRead`, in call order.
    var markedThreadIDs: [String] {
        lock.withLock { _markedThreadIDs }
    }

    var approvals: [Approve] {
        lock.withLock { _approvals }
    }

    var merges: [Merge] {
        lock.withLock { _merges }
    }

    func recordMarkRead(_ threadID: String) {
        lock.withLock { _markedThreadIDs.append(threadID) }
    }

    func recordApprove(repo: String, number: Int) {
        lock.withLock { _approvals.append(Approve(repo: repo, number: number)) }
    }

    func recordMerge(repo: String, number: Int, method: MergeMethod) {
        lock.withLock { _merges.append(Merge(repo: repo, number: number, method: method)) }
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
    /// When set, only `notifications()` throws this error — section queries still succeed.
    /// Lets tests exercise the best-effort guarantee (a flaky inbox never blanks sections).
    var notificationsError: Error?
    /// When set, only the mutating actions (approve/merge) throw — search still succeeds.
    /// Lets a test populate the store via a real refresh, then fail just the action.
    var actionError: Error?
    /// Captures side-effecting calls (mark-as-read, approve, merge) for assertions.
    var recorder = CallRecorder()
    /// Returned by `pullRequest`; defaults to a stub so CI hydration works without explicit setup.
    var pullRequestResult: PullRequestDetail = .stub()
    /// Returned by `checkRuns` (defaults to empty, so CI hydration is a no-op unless stubbed).
    var checkRunsResult: [CheckRun] = []
    /// Returned by `currentUser()` — the account a token resolves to when validated/added.
    var currentUserResult = GitHubUser(login: "octocat", avatarURL: nil)

    func currentUser() async throws -> GitHubUser {
        if let error {
            throw error
        }
        return currentUserResult
    }

    func searchIssues(_ query: String) async throws -> [SearchIssue] {
        if let error {
            throw error
        }
        return resultsByQuery[query] ?? defaultResult
    }

    /// Returns the injected PR detail and check runs; CI hydration tests rely on these
    /// succeeding, so neither endpoint throws unless a global `error` is set elsewhere.
    func pullRequest(repo _: String, number _: Int) async throws -> PullRequestDetail {
        pullRequestResult
    }

    func checkRuns(repo _: String, ref _: String) async throws -> [CheckRun] {
        checkRunsResult
    }

    /// Records the approval, then throws `error` if one is injected so error paths are testable.
    func approvePullRequest(repo: String, number: Int) async throws {
        recorder.recordApprove(repo: repo, number: number)
        if let error { throw error }
        if let actionError { throw actionError }
    }

    /// Records the merge, then throws `error` if one is injected so error paths are testable.
    func mergePullRequest(repo: String, number: Int, method: MergeMethod) async throws {
        recorder.recordMerge(repo: repo, number: number, method: method)
        if let error { throw error }
        if let actionError { throw actionError }
    }

    func markNotificationRead(threadID: String) async throws {
        if let error {
            throw error
        }
        recorder.recordMarkRead(threadID)
    }

    func notifications() async throws -> [GitHubNotification] {
        if let error = notificationsError ?? error {
            throw error
        }
        return notificationsResult
    }
}

/// A `GitHubAPI` fake that blocks inside `checkRuns` until the test explicitly releases it,
/// letting tests drive the race where a CI hydration wave is in flight while state changes
/// underneath it (e.g. sign-out). Actor isolation keeps it `Sendable`-clean.
actor GatedGitHubAPI: GitHubAPI {
    private let searchResult: [SearchIssue]
    private let pullRequestResult: PullRequestDetail
    private let checkRunsResult: [CheckRun]

    private var releaseGate: CheckedContinuation<Void, Never>?
    private var released = false
    private var enteredGate: CheckedContinuation<Void, Never>?
    private var entered = false

    init(search: [SearchIssue], pullRequest: PullRequestDetail, checkRuns: [CheckRun]) {
        searchResult = search
        pullRequestResult = pullRequest
        checkRunsResult = checkRuns
    }

    /// Suspends until `checkRuns` has been entered (the hydration wave is blocked in flight).
    func waitUntilBlocked() async {
        if entered { return }
        await withCheckedContinuation { enteredGate = $0 }
    }

    /// Releases the blocked `checkRuns` call so the wave can finish.
    func release() {
        released = true
        releaseGate?.resume()
        releaseGate = nil
    }

    func searchIssues(_: String) async throws -> [SearchIssue] {
        searchResult
    }

    func pullRequest(repo _: String, number _: Int) async throws -> PullRequestDetail {
        pullRequestResult
    }

    func checkRuns(repo _: String, ref _: String) async throws -> [CheckRun] {
        entered = true
        enteredGate?.resume()
        enteredGate = nil
        if !released {
            await withCheckedContinuation { releaseGate = $0 }
        }
        return checkRunsResult
    }

    func currentUser() async throws -> GitHubUser {
        GitHubUser(login: "gated", avatarURL: nil)
    }

    private enum Unstubbed: Error { case notImplemented }
    func approvePullRequest(repo _: String, number _: Int) async throws {
        throw Unstubbed.notImplemented
    }

    func mergePullRequest(repo _: String, number _: Int, method _: MergeMethod) async throws {
        throw Unstubbed.notImplemented
    }

    func markNotificationRead(threadID _: String) async throws {
        throw Unstubbed.notImplemented
    }

    func notifications() async throws -> [GitHubNotification] {
        throw Unstubbed.notImplemented
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
    ///
    /// `subjectURL` defaults to a public-GitHub PR API URL; pass a custom string (e.g. an
    /// Enterprise/Issue URL) to override, or `nil` to emit a `null` subject URL.
    static func stub(
        id: String,
        unread: Bool = true,
        reason: String = "review_requested",
        type: String = "PullRequest",
        repo: String = "octo/repo",
        title: String = "Stub notification",
        subjectURL: String? = "https://api.github.com/repos/octo/repo/pulls/1"
    )
    -> GitHubNotification {
        let urlLine = subjectURL.map { "\"url\": \"\($0)\"" } ?? "\"url\": null"
        let json = """
        {
          "id": "\(id)",
          "unread": \(unread),
          "reason": "\(reason)",
          "updated_at": "2026-01-01T00:00:00Z",
          "subject": {
            "title": "\(title)",
            "type": "\(type)",
            \(urlLine)
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

private let testDecoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
}()

extension PullRequestDetail {
    /// Minimal detail carrying a head SHA and branch ref, decoded from a synthetic payload.
    static func stub(number: Int = 1, headSHA: String = "abc1234def", headRef: String = "feature/stub")
    -> PullRequestDetail {
        let json = """
        {
          "id": \(number),
          "number": \(number),
          "title": "Stub PR",
          "state": "open",
          "html_url": "https://github.com/octo/repo/pull/\(number)",
          "merged": false,
          "mergeable": true,
          "draft": false,
          "user": { "login": "jaylann", "avatar_url": null },
          "created_at": "2026-01-01T00:00:00Z",
          "updated_at": "2026-01-01T00:00:00Z",
          "head": { "sha": "\(headSHA)", "ref": "\(headRef)" }
        }
        """
        guard let detail = try? testDecoder.decode(PullRequestDetail.self, from: Data(json.utf8)) else {
            fatalError("PullRequestDetail.stub produced invalid JSON")
        }
        return detail
    }
}

extension CheckRun {
    /// A single check run stub with an explicit lifecycle/outcome.
    static func stub(
        id: Int = 1,
        name: String = "CI / build",
        status: String = "completed",
        conclusion: String? = "success"
    )
    -> CheckRun {
        let conclusionJSON = conclusion.map { "\"\($0)\"" } ?? "null"
        let json = """
        {
          "id": \(id),
          "name": "\(name)",
          "status": "\(status)",
          "conclusion": \(conclusionJSON),
          "started_at": "2026-01-01T00:00:00Z",
          "completed_at": "2026-01-01T00:01:42Z"
        }
        """
        guard let run = try? testDecoder.decode(CheckRun.self, from: Data(json.utf8)) else {
            fatalError("CheckRun.stub produced invalid JSON")
        }
        return run
    }
}
