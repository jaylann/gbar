import Foundation
@testable import gbar

/// Thread-safe recorder for the side-effecting calls a `FakeGitHubAPI` receives
/// (mark-as-read, approve, merge), so tests can assert on them even though the value-type,
/// `let`-held fake can't capture calls in a non-`mutating` method. `@unchecked Sendable` via a lock.
final class CallRecorder: @unchecked Sendable {
    struct Approve: Equatable {
        let repo: String
        let number: Int
        var body: String?
    }

    struct Merge: Equatable {
        let repo: String
        let number: Int
        let method: MergeMethod
    }

    private let lock = NSLock()
    private var _markedThreadIDs: [String] = []
    private var _markAllCount = 0
    private var _approvals: [Approve] = []
    private var _merges: [Merge] = []
    private var _searchCount = 0
    private var _pullRequestQueue: [PullRequestDetail] = []
    private var _pullRequestCount = 0
    private var _checkRunsCount = 0
    private var _batchCount = 0

    /// Total `pullRequest` calls received — lets a test assert the post-approve poll retried.
    var pullRequestCount: Int {
        lock.withLock { _pullRequestCount }
    }

    /// Total `checkRuns` calls received — lets a test assert an unchanged PR still polls CI even
    /// when its detail refetch is skipped.
    var checkRunsCount: Int {
        lock.withLock { _checkRunsCount }
    }

    func recordCheckRuns() {
        lock.withLock { _checkRunsCount += 1 }
    }

    /// Total `pullRequestBatch` calls received — lets a test assert a refresh hydrated via one
    /// GraphQL round-trip per account instead of the per-PR REST triple.
    var batchCount: Int {
        lock.withLock { _batchCount }
    }

    func recordBatch() {
        lock.withLock { _batchCount += 1 }
    }

    /// Thread IDs passed to `markNotificationRead`, in call order.
    var markedThreadIDs: [String] {
        lock.withLock { _markedThreadIDs }
    }

    /// Number of `markAllNotificationsRead` (bulk) calls received.
    var markAllCount: Int {
        lock.withLock { _markAllCount }
    }

    var approvals: [Approve] {
        lock.withLock { _approvals }
    }

    var merges: [Merge] {
        lock.withLock { _merges }
    }

    /// Total `searchIssues` calls received — lets a test assert a refresh ran as a single wave.
    var searchCount: Int {
        lock.withLock { _searchCount }
    }

    func recordSearch() {
        lock.withLock { _searchCount += 1 }
    }

    func recordMarkRead(_ threadID: String) {
        lock.withLock { _markedThreadIDs.append(threadID) }
    }

    func recordMarkAll() {
        lock.withLock { _markAllCount += 1 }
    }

    func recordApprove(repo: String, number: Int, body: String?) {
        lock.withLock { _approvals.append(Approve(repo: repo, number: number, body: body)) }
    }

    func recordMerge(repo: String, number: Int, method: MergeMethod) {
        lock.withLock { _merges.append(Merge(repo: repo, number: number, method: method)) }
    }

    /// Seed a sequence of PR details drained one-per-call by `pullRequest`, so a test can model
    /// GitHub's async `mergeable_state` recompute (e.g. `"blocked"` then `"clean"`).
    func setPullRequestQueue(_ details: [PullRequestDetail]) {
        lock.withLock { _pullRequestQueue = details }
    }

    /// Return the next queued PR detail, or `nil` once exhausted (caller falls back to its stub).
    /// Always bumps the call counter.
    func nextPullRequest() -> PullRequestDetail? {
        lock.withLock {
            _pullRequestCount += 1
            guard !_pullRequestQueue.isEmpty else { return nil }
            return _pullRequestQueue.count == 1 ? _pullRequestQueue[0] : _pullRequestQueue.removeFirst()
        }
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
    /// Returned by `reviews` (defaults to empty → the viewer hasn't reviewed).
    var reviewsResult: [PullRequestReview] = []
    /// Returned by `repository` — defaults to full push access so Merge isn't gated unless stubbed.
    var repositoryResult: RepositoryInfo = .stub(push: true)
    /// When set, `checkRuns` throws this — simulates a transient CI-fetch failure while the PR
    /// still loads into its section (so its CI baseline must be preserved, not wiped).
    var checkRunsError: Error?
    /// When set, `pullRequestBatch` throws this — simulates the GraphQL path being unavailable
    /// (a GHE server missing a field, a transport error) so the store's REST fallback is testable.
    var batchError: Error?
    /// Returned by `currentUser()` — the account a token resolves to when validated/added.
    var currentUserResult = GitHubUser(login: "octocat", avatarURL: nil)
    /// Returned by `starredRepos()` — the `owner/name` slugs the account has starred.
    var starredResult: [String] = []
    /// When set, only `starredRepos()` throws — lets tests exercise the best-effort guarantee
    /// (a failed starred fetch never surfaces an error message, just skips advancing the set).
    var starredError: Error?
    /// Returned by `workflowRuns(repo:)`, keyed by exact slug (falling back to the default).
    var workflowRunsByRepo: [String: [WorkflowRun]] = [:]
    var workflowRunsResult: [WorkflowRun] = []
    /// Returned by `releases(repo:)`, keyed by exact slug (falling back to the default).
    var releasesByRepo: [String: [Release]] = [:]
    var releasesResult: [Release] = []

    func currentUser() async throws -> GitHubUser {
        if let error {
            throw error
        }
        return currentUserResult
    }

    func searchIssues(_ query: String) async throws -> [SearchIssue] {
        recorder.recordSearch()
        if let error {
            throw error
        }
        return resultsByQuery[query] ?? defaultResult
    }

    /// Returns the injected PR detail and check runs; CI hydration tests rely on these
    /// succeeding, so neither endpoint throws unless a global `error` is set elsewhere.
    func pullRequest(repo _: String, number _: Int) async throws -> PullRequestDetail {
        recorder.nextPullRequest() ?? pullRequestResult
    }

    func checkRuns(repo _: String, ref _: String) async throws -> [CheckRun] {
        recorder.recordCheckRuns()
        if let checkRunsError {
            throw checkRunsError
        }
        return checkRunsResult
    }

    func reviews(repo _: String, number _: Int) async throws -> [PullRequestReview] {
        if let error { throw error }
        return reviewsResult
    }

    /// Composes a bundle per ref from the same stubs the REST path uses (`pullRequestResult` +
    /// `reviewsResult` + `checkRunsResult` + `repositoryResult`), so a store test exercises the
    /// GraphQL hydration path with the existing knobs. `batchError` (or a global `error`) makes it
    /// throw, driving the store's REST fallback.
    func pullRequestBatch(_ refs: [PRRef]) async throws -> [PRRef: PullRequestBundle] {
        recorder.recordBatch()
        if let batchError { throw batchError }
        if let error { throw error }
        let perms = repositoryResult.permissions
        let canMerge = (perms?.push ?? false) || (perms?.maintain ?? false) || (perms?.admin ?? false)
        let mergeInfo = RepoMergeInfo(canMerge: canMerge, allowedMethods: repositoryResult.allowedMergeMethods)
        return refs.reduce(into: [:]) { result, ref in
            result[ref] = PullRequestBundle(
                detail: pullRequestResult,
                reviews: reviewsResult,
                checkRuns: checkRunsResult,
                mergeInfo: mergeInfo
            )
        }
    }

    func repository(repo _: String) async throws -> RepositoryInfo {
        if let error { throw error }
        return repositoryResult
    }

    /// Records the approval, then throws `error` if one is injected so error paths are testable.
    func approvePullRequest(repo: String, number: Int, body: String?) async throws {
        recorder.recordApprove(repo: repo, number: number, body: body)
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

    /// Records the bulk mark-all call, then throws `error`/`actionError` if injected so the
    /// store's failure path (items retained, error surfaced) is testable.
    func markAllNotificationsRead() async throws {
        recorder.recordMarkAll()
        if let error { throw error }
        if let actionError { throw actionError }
    }

    func notifications() async throws -> [GitHubNotification] {
        if let error = notificationsError ?? error {
            throw error
        }
        return notificationsResult
    }

    func starredRepos() async throws -> [String] {
        if let error = starredError ?? error {
            throw error
        }
        return starredResult
    }

    func workflowRuns(repo: String) async throws -> [WorkflowRun] {
        if let error {
            throw error
        }
        return workflowRunsByRepo[repo] ?? workflowRunsResult
    }

    func releases(repo: String) async throws -> [Release] {
        if let error {
            throw error
        }
        return releasesByRepo[repo] ?? releasesResult
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

    func reviews(repo _: String, number _: Int) async throws -> [PullRequestReview] {
        []
    }

    func repository(repo _: String) async throws -> RepositoryInfo {
        .stub(push: true)
    }

    /// Park the caller inside the gate: signal it has been entered (unblocking `waitUntilBlocked`),
    /// then suspend until `release()`. Shared by `checkRuns` and `pullRequestBatch` so the in-flight
    /// race test drives whichever hydration path the store takes.
    private func enterGateAndWait() async {
        entered = true
        enteredGate?.resume()
        enteredGate = nil
        if !released {
            await withCheckedContinuation { releaseGate = $0 }
        }
    }

    func checkRuns(repo _: String, ref _: String) async throws -> [CheckRun] {
        await enterGateAndWait()
        return checkRunsResult
    }

    /// GraphQL batch path — blocks in the same gate as `checkRuns` so the sign-out-during-hydration
    /// race test applies whether the store hydrates via GraphQL (default) or REST.
    func pullRequestBatch(_ refs: [PRRef]) async throws -> [PRRef: PullRequestBundle] {
        await enterGateAndWait()
        let mergeInfo = RepoMergeInfo(canMerge: true, allowedMethods: MergeMethod.allCases)
        return refs.reduce(into: [:]) { out, ref in
            out[ref] = PullRequestBundle(
                detail: pullRequestResult,
                reviews: [],
                checkRuns: checkRunsResult,
                mergeInfo: mergeInfo
            )
        }
    }

    func currentUser() async throws -> GitHubUser {
        GitHubUser(login: "gated", avatarURL: nil)
    }

    private enum Unstubbed: Error { case notImplemented }
    func approvePullRequest(repo _: String, number _: Int, body _: String?) async throws {
        throw Unstubbed.notImplemented
    }

    func mergePullRequest(repo _: String, number _: Int, method _: MergeMethod) async throws {
        throw Unstubbed.notImplemented
    }

    func markNotificationRead(threadID _: String) async throws {
        throw Unstubbed.notImplemented
    }

    func markAllNotificationsRead() async throws {
        throw Unstubbed.notImplemented
    }

    func notifications() async throws -> [GitHubNotification] {
        throw Unstubbed.notImplemented
    }

    func starredRepos() async throws -> [String] {
        []
    }

    func workflowRuns(repo _: String) async throws -> [WorkflowRun] {
        []
    }

    func releases(repo _: String) async throws -> [Release] {
        []
    }
}

extension SearchIssue {
    /// Builds a minimal `SearchIssue` for tests by decoding a synthetic payload, so tests
    /// don't depend on the (non-public) memberwise initializer.
    /// `updatedAt` defaults to *now* so an item reads as recently-active and survives the
    /// notification recency gate; pass an old date to exercise the stale-item path.
    static func stub(
        id: Int,
        number: Int = 1,
        title: String = "Stub",
        repo: String = "octo/repo",
        updatedAt: Date = Date()
    )
    -> SearchIssue {
        let json = """
        {
          "id": \(id),
          "number": \(number),
          "title": "\(title)",
          "html_url": "https://github.com/\(repo)/pull/\(number)",
          "state": "open",
          "created_at": "2026-01-01T00:00:00Z",
          "updated_at": "\(ISO8601DateFormatter().string(from: updatedAt))",
          "user": { "login": "jaylann", "avatar_url": null },
          "repository_url": "https://api.github.com/repos/\(repo)",
          "pull_request": { "html_url": "https://github.com/\(repo)/pull/\(number)", "merged_at": null },
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
    static func stub(
        number: Int = 1,
        headSHA: String = "abc1234def",
        headRef: String = "feature/stub",
        state: String = "open",
        mergeableState: String = "clean",
        draft: Bool = false
    )
    -> PullRequestDetail {
        let json = """
        {
          "id": \(number),
          "number": \(number),
          "title": "Stub PR",
          "state": "\(state)",
          "html_url": "https://github.com/octo/repo/pull/\(number)",
          "merged": false,
          "mergeable": true,
          "mergeable_state": "\(mergeableState)",
          "draft": \(draft),
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

extension PullRequestReview {
    /// A single review stub by `login` with the given `state`.
    static func stub(login: String, state: String, submittedAt: String = "2026-01-01T00:00:00Z")
    -> PullRequestReview {
        let json = """
        {
          "user": { "login": "\(login)", "avatar_url": null },
          "state": "\(state)",
          "submitted_at": "\(submittedAt)"
        }
        """
        guard let review = try? testDecoder.decode(PullRequestReview.self, from: Data(json.utf8)) else {
            fatalError("PullRequestReview.stub produced invalid JSON")
        }
        return review
    }
}

extension RepositoryInfo {
    /// Repository info carrying the viewer's `push` permission (the merge gate signal) plus the
    /// repo's enabled merge strategies (default all three, matching a typical repo).
    static func stub(
        push: Bool,
        maintain: Bool = false,
        admin: Bool = false,
        allowMerge: Bool = true,
        allowSquash: Bool = true,
        allowRebase: Bool = true
    )
    -> RepositoryInfo {
        let json = """
        {
          "permissions": { "push": \(push), "maintain": \(maintain), "admin": \(admin) },
          "allow_merge_commit": \(allowMerge),
          "allow_squash_merge": \(allowSquash),
          "allow_rebase_merge": \(allowRebase)
        }
        """
        guard let info = try? testDecoder.decode(RepositoryInfo.self, from: Data(json.utf8)) else {
            fatalError("RepositoryInfo.stub produced invalid JSON")
        }
        return info
    }
}

extension WorkflowRun {
    /// A single workflow-run stub with an explicit lifecycle/outcome and trigger event.
    static func stub(
        id: Int = 1,
        name: String = "CI",
        displayTitle: String? = "Fix the thing",
        headBranch: String? = "stage",
        event: String = "push",
        status: String = "completed",
        conclusion: String? = "success",
        runNumber: Int = 1,
        updatedAt: String = "2026-01-01T00:01:42Z"
    )
    -> WorkflowRun {
        let displayTitleJSON = displayTitle.map { "\"\($0)\"" } ?? "null"
        let headBranchJSON = headBranch.map { "\"\($0)\"" } ?? "null"
        let conclusionJSON = conclusion.map { "\"\($0)\"" } ?? "null"
        let json = """
        {
          "id": \(id),
          "name": "\(name)",
          "display_title": \(displayTitleJSON),
          "head_branch": \(headBranchJSON),
          "event": "\(event)",
          "status": "\(status)",
          "conclusion": \(conclusionJSON),
          "html_url": "https://github.com/octo/repo/actions/runs/\(id)",
          "run_number": \(runNumber),
          "created_at": "2026-01-01T00:00:00Z",
          "updated_at": "\(updatedAt)",
          "run_started_at": "2026-01-01T00:00:00Z"
        }
        """
        guard let run = try? testDecoder.decode(WorkflowRun.self, from: Data(json.utf8)) else {
            fatalError("WorkflowRun.stub produced invalid JSON")
        }
        return run
    }
}

extension Release {
    /// A single release stub. `publishedAt` nil emits a draft-shaped payload.
    static func stub(
        id: Int = 1,
        tagName: String = "v1.0.0",
        name: String? = "v1.0.0",
        publishedAt: String? = "2026-01-01T00:00:00Z",
        draft: Bool = false,
        prerelease: Bool = false
    )
    -> Release {
        let nameJSON = name.map { "\"\($0)\"" } ?? "null"
        let publishedJSON = publishedAt.map { "\"\($0)\"" } ?? "null"
        let json = """
        {
          "id": \(id),
          "tag_name": "\(tagName)",
          "name": \(nameJSON),
          "html_url": "https://github.com/octo/repo/releases/tag/\(tagName)",
          "published_at": \(publishedJSON),
          "created_at": "2026-01-01T00:00:00Z",
          "draft": \(draft),
          "prerelease": \(prerelease),
          "author": { "login": "jaylann", "avatar_url": null }
        }
        """
        guard let release = try? testDecoder.decode(Release.self, from: Data(json.utf8)) else {
            fatalError("Release.stub produced invalid JSON")
        }
        return release
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
