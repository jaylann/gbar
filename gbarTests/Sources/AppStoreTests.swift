import XCTest
@testable import gbar

@MainActor
final class AppStoreTests: XCTestCase {
    private func makeURL() throws -> URL {
        try XCTUnwrap(URL(string: "https://api.github.com"))
    }

    private func makeAccount(login: String = "octocat", host: String = "https://api.github.com") throws -> Account {
        try Account(login: login, avatarURL: nil, kind: .oauth, apiBaseURL: XCTUnwrap(URL(string: host)))
    }

    private func makeStore(api: FakeGitHubAPI, accounts: [Account]? = nil) throws -> AppStore {
        let url = try makeURL()
        let accts = try accounts ?? [makeAccount()]
        return AppStore(apiBaseURL: url, accounts: accts, makeAPI: { _, _ in api })
    }

    /// Wrap a bare issue in an `AccountItem` tagged with the default test account.
    private func item(_ issue: SearchIssue) throws -> AccountItem {
        try AccountItem(account: makeAccount(), issue: issue)
    }

    private func key(_ prID: Int, account: String = "octocat") -> PRCheckKey {
        PRCheckKey(accountID: account, prID: prID)
    }

    func testRefreshHappyPathPopulatesSections() async throws {
        var fake = FakeGitHubAPI()
        fake.defaultResult = SearchIssue.stubs(count: 2)
        let store = try makeStore(api: fake)

        await store.refresh()

        XCTAssertEqual(store.sections.count, SearchQuery.defaults.count)
        XCTAssertEqual(store.sections.count, 4)
        XCTAssertTrue(store.sections.allSatisfy { !$0.items.isEmpty })
        XCTAssertNil(store.lastErrorMessage)
        XCTAssertFalse(store.sessionExpired)
        XCTAssertTrue(store.hasLoaded)
        XCTAssertFalse(store.isRefreshing)
    }

    func testRefreshUnauthorizedSetsSessionExpired() async throws {
        var fake = FakeGitHubAPI()
        fake.error = GitHubClient.ClientError.http(401)
        let store = try makeStore(api: fake)

        await store.refresh()

        XCTAssertTrue(store.sessionExpired)
        XCTAssertNotNil(store.lastErrorMessage)
    }

    func testRefreshOtherErrorSetsMessageWithoutSessionExpired() async throws {
        struct Boom: Error {}
        var fake = FakeGitHubAPI()
        fake.error = Boom()
        let store = try makeStore(api: fake)

        await store.refresh()

        XCTAssertNotNil(store.lastErrorMessage)
        XCTAssertFalse(store.sessionExpired)
    }

    /// Two overlapping `refresh()` calls must coalesce into a single fetch wave (#10). Without the
    /// single-flight guard, the second call starts its own wave and doubles the section queries.
    func testConcurrentRefreshCoalescesIntoSingleWave() async throws {
        let fake = FakeGitHubAPI()
        let store = try makeStore(api: fake)

        async let first: Void = store.refresh()
        async let second: Void = store.refresh()
        _ = await (first, second)

        // One account × the default saved queries — exactly one wave, not two.
        XCTAssertEqual(fake.recorder.searchCount, SearchQuery.defaults.count)
        XCTAssertFalse(store.isRefreshing)
    }

    // MARK: - Quick actions

    func testApproveRecordsCallOnHappyPath() async throws {
        let fake = FakeGitHubAPI()
        let store = try makeStore(api: fake)
        let pr = try item(SearchIssue.stub(id: 1, number: 42))

        await store.approve(pr)

        XCTAssertEqual(fake.recorder.approvals, [.init(repo: "octo/repo", number: 42)])
        XCTAssertNil(store.lastErrorMessage)
    }

    func testApproveForwardsReviewBody() async throws {
        let fake = FakeGitHubAPI()
        let store = try makeStore(api: fake)
        let pr = try item(SearchIssue.stub(id: 1, number: 42))

        await store.approve(pr, message: "  LGTM  ")

        // The message is trimmed before it's forwarded as the review body.
        XCTAssertEqual(fake.recorder.approvals, [.init(repo: "octo/repo", number: 42, body: "LGTM")])
    }

    func testApproveWithBlankMessageSendsNoBody() async throws {
        let fake = FakeGitHubAPI()
        let store = try makeStore(api: fake)
        let pr = try item(SearchIssue.stub(id: 1, number: 42))

        await store.approve(pr, message: "   ")

        // A whitespace-only message posts a plain approval (nil body), not an empty string.
        XCTAssertEqual(fake.recorder.approvals, [.init(repo: "octo/repo", number: 42, body: nil)])
    }

    func testApproveErrorSetsMessage() async throws {
        struct Boom: Error {}
        var fake = FakeGitHubAPI()
        fake.error = Boom()
        let store = try makeStore(api: fake)

        try await store.approve(item(SearchIssue.stub(id: 1, number: 42)))

        XCTAssertEqual(fake.recorder.approvals.count, 1)
        XCTAssertNotNil(store.lastErrorMessage)
    }

    /// After a successful approve, the PR's gate must update immediately — Approve hidden,
    /// Merge shown — without a full section refresh. A prior `refresh()` seeds `repoMergeInfo`,
    /// so `mergeable` here reflects *verified* push access (push: true), not the optimistic
    /// pre-hydration fallback. The stub PR is authored by `jaylann` while the account is
    /// `octocat`, so it's not the viewer's own PR and reviews are consulted.
    func testApproveRefreshesGateImmediately() async throws {
        var fake = FakeGitHubAPI()
        fake.defaultResult = [SearchIssue.stub(id: 1, number: 42)]
        fake.pullRequestResult = .stub(number: 42, mergeableState: "clean")
        fake.repositoryResult = .stub(push: true)
        fake.reviewsResult = [] // viewer hasn't approved yet
        let store = try makeStore(api: fake) // account login = octocat

        // Seed the gate + repo merge info via a real wave, so the later re-hydration exercises
        // the verified push-access path rather than the optimistic nil-mergeInfo fallback.
        await store.refresh()
        let pr = try XCTUnwrap(store.prSections.flatMap(\.items).first { $0.issue.number == 42 })
        try await waitUntil { store.gate(for: pr) != nil }
        XCTAssertEqual(store.gate(for: pr)?.alreadyApproved, false)
        let searchesBeforeApprove = fake.recorder.searchCount

        // The viewer approves; the follow-up client now reports their APPROVED review.
        var approvedFake = fake
        approvedFake.reviewsResult = [.stub(login: "octocat", state: "APPROVED")]
        let approved = approvedFake
        store.makeAPI = { _, _ in approved }
        await store.approve(pr)

        // The gate re-hydrated inline — approve fired no extra section search.
        XCTAssertEqual(fake.recorder.searchCount, searchesBeforeApprove)
        let gate = try XCTUnwrap(store.gate(for: pr))
        XCTAssertTrue(gate.alreadyApproved) // Approve button now hidden
        XCTAssertTrue(gate.mergeable) // verified push access → Merge shown
    }

    /// GitHub recomputes `mergeable_state` asynchronously after an approval, so the immediate
    /// refetch still reads the stale `"blocked"`. Approve must hide at once (strongly-consistent
    /// review) while the background poll keeps refetching until the recompute lands (`"clean"`) and
    /// only then reveals Merge — this is the bug the single-shot refresh missed.
    func testApprovePollsUntilMergeableStateRecomputes() async throws {
        var fake = FakeGitHubAPI()
        fake.defaultResult = [SearchIssue.stub(id: 1, number: 42)]
        fake.pullRequestResult = .stub(number: 42, mergeableState: "blocked")
        fake.repositoryResult = .stub(push: true)
        fake.reviewsResult = []
        let store = try makeStore(api: fake) // account login = octocat
        store.sleep = { _ in } // run the backoff schedule instantly

        await store.refresh()
        let pr = try XCTUnwrap(store.prSections.flatMap(\.items).first { $0.issue.number == 42 })
        try await waitUntil { store.gate(for: pr) != nil }
        XCTAssertEqual(store.gate(for: pr)?.mergeable, false) // seeded blocked

        // The viewer approves. The follow-up client reports their APPROVED review, and the PR detail
        // recomputes over two fetches: stale "blocked" (immediate refresh), then "clean" (poll).
        var approvedFake = fake
        approvedFake.reviewsResult = [.stub(login: "octocat", state: "APPROVED")]
        fake.recorder.setPullRequestQueue([
            .stub(number: 42, mergeableState: "blocked"),
            .stub(number: 42, mergeableState: "clean"),
        ])
        let callsBefore = fake.recorder.pullRequestCount
        let approved = approvedFake
        store.makeAPI = { _, _ in approved }
        await store.approve(pr)

        // Approve flips synchronously off the immediate refresh; the background poll then reveals
        // Merge — await it (rather than sleeping) so the assertion is deterministic.
        XCTAssertTrue(try XCTUnwrap(store.gate(for: pr)).alreadyApproved) // Approve hidden at once
        await store.mergeReadinessTask?.value
        XCTAssertTrue(try XCTUnwrap(store.gate(for: pr)).mergeable) // poll past "blocked" → Merge shown
        XCTAssertGreaterThan(fake.recorder.pullRequestCount - callsBefore, 1) // it retried
    }

    /// A PR that stays `"blocked"` across every poll (e.g. a second required approval) must end with
    /// Merge hidden — the poll gives up cleanly rather than flipping it on optimistically.
    func testApprovePollLeavesMergeBlockedWhenNeverRecomputes() async throws {
        var fake = FakeGitHubAPI()
        fake.defaultResult = [SearchIssue.stub(id: 1, number: 42)]
        fake.pullRequestResult = .stub(number: 42, mergeableState: "blocked")
        fake.repositoryResult = .stub(push: true)
        fake.reviewsResult = []
        let store = try makeStore(api: fake)
        store.sleep = { _ in }

        await store.refresh()
        let pr = try XCTUnwrap(store.prSections.flatMap(\.items).first { $0.issue.number == 42 })
        try await waitUntil { store.gate(for: pr) != nil }

        var approvedFake = fake
        approvedFake.reviewsResult = [.stub(login: "octocat", state: "APPROVED")]
        let approved = approvedFake
        store.makeAPI = { _, _ in approved }
        let callsBefore = fake.recorder.pullRequestCount
        await store.approve(pr)
        await store.mergeReadinessTask?.value

        let gate = try XCTUnwrap(store.gate(for: pr))
        XCTAssertTrue(gate.alreadyApproved)
        XCTAssertFalse(gate.mergeable) // still blocked → Merge stays hidden
        // Ran the whole schedule: the immediate refresh plus one poll fetch per backoff delay.
        XCTAssertEqual(fake.recorder.pullRequestCount - callsBefore, AppStore.approveRefreshRetryDelays.count + 1)
    }

    func testMergeRecordsCallAndRemovesItemOptimistically() async throws {
        var fake = FakeGitHubAPI()
        fake.defaultResult = SearchIssue.stubs(count: 2) // ids/numbers 0 and 1
        let store = try makeStore(api: fake)
        await store.refresh()
        let target = try XCTUnwrap(store.sections.first?.items.first) // id 0

        await store.merge(target, method: .squash)

        XCTAssertEqual(
            fake.recorder.merges,
            [.init(repo: "octo/repo", number: target.issue.number, method: .squash)]
        )
        XCTAssertNil(store.lastErrorMessage)
        // The merged PR is gone from every section; the other item remains.
        XCTAssertTrue(store.sections.allSatisfy { section in section.items.allSatisfy { $0.id != target.id } })
        XCTAssertTrue(store.sections.contains { section in section.items.contains { $0.id != target.id } })
    }

    func testMergeErrorSetsMessage() async throws {
        struct Boom: Error {}
        var fake = FakeGitHubAPI()
        fake.error = Boom()
        let store = try makeStore(api: fake)

        try await store.merge(item(SearchIssue.stub(id: 7, number: 7)), method: .merge)

        XCTAssertEqual(fake.recorder.merges.count, 1)
        XCTAssertNotNil(store.lastErrorMessage)
    }

    func testMergeErrorKeepsItemInSections() async throws {
        struct Boom: Error {}
        var fake = FakeGitHubAPI()
        // Search succeeds so the store is populated; only the merge action fails.
        fake.defaultResult = SearchIssue.stubs(count: 2)
        fake.actionError = Boom()
        let store = try makeStore(api: fake)
        await store.refresh()
        let target = try XCTUnwrap(store.sections.first?.items.first)

        await store.merge(target, method: .merge)

        XCTAssertNotNil(store.lastErrorMessage)
        // A failed merge must NOT remove the row: the target is still present.
        XCTAssertTrue(store.sections.contains { section in section.items.contains { $0.id == target.id } })
    }

    func testMergeUnauthorizedSetsSessionExpired() async throws {
        var fake = FakeGitHubAPI()
        fake.error = GitHubClient.ClientError.http(401)
        let store = try makeStore(api: fake)

        try await store.merge(item(SearchIssue.stub(id: 1, number: 42)), method: .merge)

        XCTAssertTrue(store.sessionExpired)
        // Regression: quick-action 401s must record WHICH account expired, like the refresh
        // path does, so the popover can offer an in-place "Reconnect <login>".
        XCTAssertEqual(store.expiredAccountID, "octocat")
        XCTAssertEqual(store.lastErrorMessage, "Session expired — reconnect in Settings.")
    }

    func testApproveUnauthorizedSetsSessionExpired() async throws {
        var fake = FakeGitHubAPI()
        fake.error = GitHubClient.ClientError.http(401)
        let store = try makeStore(api: fake)

        try await store.approve(item(SearchIssue.stub(id: 1, number: 42)))

        XCTAssertTrue(store.sessionExpired)
        XCTAssertEqual(store.expiredAccountID, "octocat")
        XCTAssertEqual(store.lastErrorMessage, "Session expired — reconnect in Settings.")
    }

    func testRefreshHydratesPRChecks() async throws {
        var fake = FakeGitHubAPI()
        fake.defaultResult = [SearchIssue.stub(id: 100, number: 7)]
        fake.pullRequestResult = .stub(number: 7, headSHA: "deadbeef", headRef: "feature/ci")
        fake.checkRunsResult = [
            .stub(id: 1, name: "CI / build", conclusion: "success"),
            .stub(id: 2, name: "CI / lint", conclusion: "failure"),
        ]
        let store = try makeStore(api: fake)

        await store.refresh()
        // CI hydration runs in a detached, non-blocking task — wait for it to land.
        try await waitUntil { store.prChecks[self.key(100)] != nil }

        let checks = try XCTUnwrap(store.prChecks[key(100)])
        XCTAssertEqual(checks.status, .failure) // failure dominates the rollup
        XCTAssertEqual(checks.checks.count, 2)
        XCTAssertEqual(checks.checks.first?.branch, "feature/ci") // branch = head ref, not SHA
    }

    /// The default hydration path issues one GraphQL `pullRequestBatch` per account and no per-PR
    /// REST detail/checks calls — the whole point of issue #83.
    func testRefreshHydratesViaGraphQLBatch() async throws {
        var fake = FakeGitHubAPI()
        fake.defaultResult = [SearchIssue.stub(id: 100, number: 7)]
        fake.pullRequestResult = .stub(number: 7, headSHA: "deadbeef", headRef: "feature/ci", mergeableState: "clean")
        fake.checkRunsResult = [.stub(id: 1, name: "CI / build", conclusion: "success")]
        fake.repositoryResult = .stub(push: true)
        let store = try makeStore(api: fake)

        await store.refresh()
        await store.awaitChecksHydration()

        XCTAssertEqual(fake.recorder.batchCount, 1, "one GraphQL round-trip for the account")
        XCTAssertEqual(fake.recorder.pullRequestCount, 0, "no per-PR REST detail fetch on the batch path")
        XCTAssertEqual(fake.recorder.checkRunsCount, 0, "no per-PR REST check-runs fetch on the batch path")
        XCTAssertEqual(store.prChecks[key(100)]?.status, .success)
        XCTAssertEqual(store.prGates[key(100)]?.mergeable, true) // clean + push access, from the bundle
    }

    /// When the GraphQL batch throws (a GHE server missing a field, a transport error), the store
    /// falls back to the per-PR REST hydration and still lands the same state.
    func testGraphQLBatchFailureFallsBackToREST() async throws {
        struct Boom: Error {}
        var fake = FakeGitHubAPI()
        fake.defaultResult = [SearchIssue.stub(id: 100, number: 7)]
        fake.pullRequestResult = .stub(number: 7, headSHA: "deadbeef", headRef: "feature/ci")
        fake.checkRunsResult = [.stub(id: 1, name: "CI / build", conclusion: "success")]
        fake.batchError = Boom() // GraphQL unavailable
        let store = try makeStore(api: fake)

        await store.refresh()
        await store.awaitChecksHydration()

        XCTAssertGreaterThanOrEqual(fake.recorder.batchCount, 1, "the batch was attempted")
        XCTAssertGreaterThan(fake.recorder.pullRequestCount, 0, "fell back to per-PR REST detail")
        XCTAssertEqual(store.prChecks[key(100)]?.status, .success, "REST fallback still hydrates CI")
    }

    func testRefreshWithNoCheckRunsLeavesPRUnhydrated() async throws {
        var fake = FakeGitHubAPI()
        fake.defaultResult = [SearchIssue.stub(id: 200, number: 8)]
        fake.pullRequestResult = .stub(number: 8)
        fake.checkRunsResult = [] // empty rollup -> nil -> no entry
        let store = try makeStore(api: fake)

        await store.refresh()
        // Deterministically await the hydration wave instead of sleeping.
        await store.awaitChecksHydration()

        XCTAssertNil(store.prChecks[key(200)])
    }

    func testRefreshPrunesPRThatDroppedOutOfList() async throws {
        var fake = FakeGitHubAPI()
        fake.defaultResult = [SearchIssue.stub(id: 100, number: 7)]
        fake.pullRequestResult = .stub(number: 7)
        fake.checkRunsResult = [.stub(id: 1, conclusion: "success")]
        let store = try makeStore(api: fake)

        await store.refresh()
        try await waitUntil { store.prChecks[self.key(100)] != nil }

        // Next refresh returns no PRs — the previous entry must be pruned, not linger.
        let empty = FakeGitHubAPI() // defaultResult is [] by default
        store.makeAPI = { _, _ in empty }
        await store.refresh()

        // Pruning happens synchronously at the start of the hydration wave.
        XCTAssertNil(store.prChecks[key(100)])
        XCTAssertTrue(store.prChecks.isEmpty)
    }

    func testSignOutAllCancelsHydrationSoPRChecksStayEmpty() async throws {
        let gated = GatedGitHubAPI(
            search: [SearchIssue.stub(id: 300, number: 9)],
            pullRequest: .stub(number: 9),
            checkRuns: [.stub(id: 1, conclusion: "success")]
        )
        let store = try makeStore(api: FakeGitHubAPI())
        store.makeAPI = { _, _ in gated }

        await store.refresh()
        // Wait until the wave is parked inside `checkRuns`, then pull the rug: sign out.
        await gated.waitUntilBlocked()
        let wave = store.checksHydrationTaskForTests
        store.signOutAll()
        // Let the parked call finish; the stale-generation guard must drop its result.
        await gated.release()
        await wave?.value

        XCTAssertTrue(store.prChecks.isEmpty)
        XCTAssertNil(store.prChecks[key(300)])
    }

    // MARK: - Action gate derivation

    func testDeriveGateMergeableStates() {
        func mergeable(_ state: String, canMerge: Bool?, draft: Bool = false, prState: String = "open") -> Bool {
            let detail = PullRequestDetail.stub(state: prState, mergeableState: state, draft: draft)
            let mergeInfo = canMerge.map { RepoMergeInfo(canMerge: $0, allowedMethods: MergeMethod.allCases) }
            return AppStore.deriveGate(detail: detail, reviews: [], login: "octocat", mergeInfo: mergeInfo).mergeable
        }
        // Clean-ish states with push access → mergeable.
        XCTAssertTrue(mergeable("clean", canMerge: true))
        XCTAssertTrue(mergeable("unstable", canMerge: true))
        XCTAssertTrue(mergeable("has_hooks", canMerge: true))
        // Unknown permission → optimistic (still shown).
        XCTAssertTrue(mergeable("clean", canMerge: nil))
        // No push access → hidden even when GitHub would allow the merge.
        XCTAssertFalse(mergeable("clean", canMerge: false))
        // Blocked / dirty / behind → not actually mergeable.
        XCTAssertFalse(mergeable("blocked", canMerge: true))
        XCTAssertFalse(mergeable("dirty", canMerge: true))
        XCTAssertFalse(mergeable("behind", canMerge: true))
        // Indeterminate state (GitHub still computing after a push) → optimistic, stays shown.
        XCTAssertTrue(mergeable("unknown", canMerge: true))
        // Draft or closed → never mergeable, even while indeterminate.
        XCTAssertFalse(mergeable("clean", canMerge: true, draft: true))
        XCTAssertFalse(mergeable("clean", canMerge: true, prState: "closed"))
        XCTAssertFalse(mergeable("unknown", canMerge: true, draft: true))
    }

    func testDeriveGateAlreadyApprovedLatestWins() {
        let detail = PullRequestDetail.stub()
        func approved(_ reviews: [PullRequestReview], login: String = "octocat") -> Bool {
            let mergeInfo = RepoMergeInfo(canMerge: true, allowedMethods: MergeMethod.allCases)
            return AppStore.deriveGate(detail: detail, reviews: reviews, login: login, mergeInfo: mergeInfo)
                .alreadyApproved
        }
        // A single approval by the viewer.
        XCTAssertTrue(approved([.stub(login: "octocat", state: "APPROVED")]))
        // Case-insensitive login match.
        XCTAssertTrue(approved([.stub(login: "OctoCat", state: "APPROVED")]))
        // Latest definitive review wins: approved then dismissed → not approved.
        XCTAssertFalse(approved([
            .stub(login: "octocat", state: "APPROVED", submittedAt: "2026-01-01T00:00:00Z"),
            .stub(login: "octocat", state: "DISMISSED", submittedAt: "2026-01-02T00:00:00Z"),
        ]))
        // Changes-requested then approved → approved.
        XCTAssertTrue(approved([
            .stub(login: "octocat", state: "CHANGES_REQUESTED", submittedAt: "2026-01-01T00:00:00Z"),
            .stub(login: "octocat", state: "APPROVED", submittedAt: "2026-01-02T00:00:00Z"),
        ]))
        // A comment-only review doesn't count as approval, and doesn't override an earlier one.
        XCTAssertTrue(approved([
            .stub(login: "octocat", state: "APPROVED", submittedAt: "2026-01-01T00:00:00Z"),
            .stub(login: "octocat", state: "COMMENTED", submittedAt: "2026-01-02T00:00:00Z"),
        ]))
        // Another user's approval is irrelevant to the viewer's gate.
        XCTAssertFalse(approved([.stub(login: "someone-else", state: "APPROVED")]))
    }

    func testDeriveGateAllowedMergeMethods() {
        let detail = PullRequestDetail.stub(mergeableState: "clean")
        func methods(_ mergeInfo: RepoMergeInfo?) -> [MergeMethod] {
            AppStore.deriveGate(detail: detail, reviews: [], login: "octocat", mergeInfo: mergeInfo).allowedMergeMethods
        }
        // The gate carries through whatever methods the repo allows, in canonical order.
        XCTAssertEqual(methods(RepoMergeInfo(canMerge: true, allowedMethods: [.squash])), [.squash])
        XCTAssertEqual(
            methods(RepoMergeInfo(canMerge: true, allowedMethods: [.merge, .rebase])),
            [.merge, .rebase]
        )
        // Not yet hydrated → optimistic: offer all three.
        XCTAssertEqual(methods(nil), MergeMethod.allCases)
    }

    func testRepositoryInfoAllowedMergeMethodsFromFlags() {
        // Only squash enabled → only squash.
        XCTAssertEqual(
            RepositoryInfo.stub(push: true, allowMerge: false, allowSquash: true, allowRebase: false)
                .allowedMergeMethods,
            [.squash]
        )
        // All enabled → all three, in canonical order.
        XCTAssertEqual(RepositoryInfo.stub(push: true).allowedMergeMethods, [.merge, .squash, .rebase])
    }

    func testRefreshHydratesGate() async throws {
        var fake = FakeGitHubAPI()
        fake.defaultResult = [SearchIssue.stub(id: 100, number: 7)]
        fake.pullRequestResult = .stub(number: 7, mergeableState: "clean")
        fake.reviewsResult = [.stub(login: "octocat", state: "APPROVED")] // viewer already approved
        fake.repositoryResult = .stub(push: true)
        let store = try makeStore(api: fake) // default account login = octocat

        await store.refresh()
        try await waitUntil { store.prGates[self.key(100)] != nil }

        let gate = try XCTUnwrap(store.prGates[key(100)])
        XCTAssertTrue(gate.alreadyApproved)
        XCTAssertTrue(gate.mergeable)
    }

    func testRefreshGateHidesMergeWithoutPushAccess() async throws {
        var fake = FakeGitHubAPI()
        fake.defaultResult = [SearchIssue.stub(id: 101, number: 8)]
        fake.pullRequestResult = .stub(number: 8, mergeableState: "clean")
        fake.repositoryResult = .stub(push: false) // read-only repo
        let store = try makeStore(api: fake)

        await store.refresh()
        try await waitUntil { store.prGates[self.key(101)] != nil }

        let gate = try XCTUnwrap(store.prGates[key(101)])
        XCTAssertFalse(gate.mergeable)
        XCTAssertFalse(gate.alreadyApproved) // no reviews stubbed
    }

    func testRefreshSkipsReviewsForOwnPR() async throws {
        var fake = FakeGitHubAPI()
        fake.defaultResult = [SearchIssue.stub(id: 102, number: 9)] // authored by jaylann
        fake.pullRequestResult = .stub(number: 9, mergeableState: "clean")
        // An approval that WOULD flip alreadyApproved if reviews were consulted for own PRs.
        fake.reviewsResult = [.stub(login: "jaylann", state: "APPROVED")]
        fake.repositoryResult = .stub(push: true)
        let account = try makeAccount(login: "jaylann")
        let store = try makeStore(api: fake, accounts: [account])

        await store.refresh()
        try await waitUntil { store.prGates[self.key(102, account: "jaylann")] != nil }

        let gate = try XCTUnwrap(store.prGates[key(102, account: "jaylann")])
        XCTAssertFalse(gate.alreadyApproved) // reviews skipped for the viewer's own PR
        XCTAssertTrue(gate.mergeable) // you can still merge your own PR
    }

    /// A maintainer (or admin) without the `push` bit can still merge — the gate signal is
    /// `push || maintain || admin`, so a maintainer-only repo must not hide Merge.
    func testRefreshGateMaintainerWithoutPushCanMerge() async throws {
        var fake = FakeGitHubAPI()
        fake.defaultResult = [SearchIssue.stub(id: 103, number: 11)]
        fake.pullRequestResult = .stub(number: 11, mergeableState: "clean")
        fake.repositoryResult = .stub(push: false, maintain: true) // maintainer, no push
        let store = try makeStore(api: fake)

        await store.refresh()
        try await waitUntil { store.prGates[self.key(103)] != nil }

        let gate = try XCTUnwrap(store.prGates[key(103)])
        XCTAssertTrue(gate.mergeable)
    }

    /// Polls `condition` on the main actor until true or the timeout elapses.
    private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("timed out waiting for condition")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func testBadgeCountDefaultsToReviewRequestedOnly() async throws {
        var fake = FakeGitHubAPI()
        // Distinct counts per query so we can verify which sections contribute.
        fake.resultsByQuery = [
            "is:open is:pr review-requested:@me": SearchIssue.stubs(count: 3),
            "is:open is:pr assignee:@me": SearchIssue.stubs(count: 2),
            "is:open is:pr author:@me": SearchIssue.stubs(count: 11),
            "is:open is:issue assignee:@me": SearchIssue.stubs(count: 13),
        ]
        let store = try makeStore(api: fake)

        await store.refresh()

        // Default badge source is review-requested only (3); nothing else contributes.
        XCTAssertEqual(store.badgeCount, 3)
        XCTAssertEqual(store.badgeTooltip, "3 PRs awaiting your review")
    }

    func testBadgeCountIsConfigurableAndDedupesSelectedSources() async throws {
        var fake = FakeGitHubAPI()
        // review-requested and assigned share PR id 3 — the same PR shows up in both. With both
        // sources selected the union is {1,2,3,4}, so the badge must count that PR once (4, not 5).
        fake.resultsByQuery = [
            "is:open is:pr review-requested:@me": [
                .stub(id: 1, number: 1),
                .stub(id: 2, number: 2),
                .stub(id: 3, number: 3),
            ],
            "is:open is:pr assignee:@me": [.stub(id: 3, number: 3), .stub(id: 4, number: 4)],
        ]
        let store = try makeStore(api: fake)
        store.badgeSources = [BadgeSource.reviewRequested.rawValue, BadgeSource.assignedPRs.rawValue]

        await store.refresh()

        XCTAssertEqual(store.badgeCount, 4)
        // Breakdown attributes the overlap to the first source, so it sums to the badge (3 + 1).
        XCTAssertEqual(store.badgeTooltip, "3 to review · 1 assigned")
    }

    func testTabCountsRouteSectionsByKind() async throws {
        var fake = FakeGitHubAPI()
        // Distinct counts per default query so we can verify PR vs issue routing.
        fake.resultsByQuery = [
            "is:open is:pr review-requested:@me": SearchIssue.stubs(count: 3),
            "is:open is:pr assignee:@me": SearchIssue.stubs(count: 2),
            "is:open is:pr author:@me": SearchIssue.stubs(count: 11),
            "is:open is:issue assignee:@me": SearchIssue.stubs(count: 13),
        ]
        let store = try makeStore(api: fake)

        await store.refresh()

        // Three PR sections (3 + 2 + 11) route to PRs; the lone issue section to Issues.
        XCTAssertEqual(store.prSections.count, 3)
        XCTAssertEqual(store.issueSections.count, 1)
        XCTAssertEqual(store.prCount, 16)
        XCTAssertEqual(store.issueCount, 13)
    }

    func testUnreadNotificationCountIgnoresReadItems() async throws {
        var fake = FakeGitHubAPI()
        fake.notificationsResult = [
            .stub(id: "1", unread: true),
            .stub(id: "2", unread: false),
            .stub(id: "3", unread: true),
        ]
        let store = try makeStore(api: fake)

        await store.refresh()

        XCTAssertEqual(store.unreadNotificationCount, 2)
    }

    func testRefreshLoadsNotifications() async throws {
        var fake = FakeGitHubAPI()
        fake.notificationsResult = [
            .stub(id: "1", title: "First"),
            .stub(id: "2", title: "Second"),
        ]
        let store = try makeStore(api: fake)

        await store.refresh()

        XCTAssertEqual(store.notifications.map(\.notification.id), ["1", "2"])
        XCTAssertNil(store.lastErrorMessage)
    }

    func testNotificationsFailureKeepsSectionsPopulated() async throws {
        struct Boom: Error {}
        var fake = FakeGitHubAPI()
        fake.defaultResult = SearchIssue.stubs(count: 2)
        // Only the inbox fetch fails; section queries still succeed.
        fake.notificationsError = Boom()
        let store = try makeStore(api: fake)

        await store.refresh()

        // Best-effort guarantee: a flaky /notifications never blanks the section lists.
        XCTAssertEqual(store.sections.count, 4)
        XCTAssertTrue(store.sections.allSatisfy { !$0.items.isEmpty })
        XCTAssertTrue(store.notifications.isEmpty)
        XCTAssertEqual(store.lastErrorMessage, "Failed to load notifications.")
    }

    func testMarkReadCallsAPIAndDropsItem() async throws {
        var fake = FakeGitHubAPI()
        fake.notificationsResult = [.stub(id: "1"), .stub(id: "2")]
        let store = try makeStore(api: fake)
        await store.refresh()

        let target = try XCTUnwrap(store.notifications.first { $0.notification.id == "1" })
        await store.markRead(target)

        XCTAssertEqual(fake.recorder.markedThreadIDs, ["1"])
        XCTAssertEqual(store.notifications.map(\.notification.id), ["2"])
        XCTAssertNil(store.lastErrorMessage)
    }

    func testMarkReadFailureSetsErrorAndKeepsItem() async throws {
        var fake = FakeGitHubAPI()
        fake.notificationsResult = [.stub(id: "1")]
        let store = try makeStore(api: fake)
        await store.refresh()

        // Flip the store's live API to one that always fails, then attempt the mark-read.
        struct Boom: Error {}
        let failing = FakeGitHubAPI(error: Boom())
        store.makeAPI = { _, _ in failing }

        let target = try XCTUnwrap(store.notifications.first)
        await store.markRead(target)

        XCTAssertEqual(store.notifications.map(\.notification.id), ["1"])
        XCTAssertNotNil(store.lastErrorMessage)
    }

    func testMarkAllReadCallsBulkAPIAndClearsInbox() async throws {
        var fake = FakeGitHubAPI()
        fake.notificationsResult = [.stub(id: "1"), .stub(id: "2")]
        let store = try makeStore(api: fake)
        await store.refresh()

        await store.markAllRead()

        XCTAssertEqual(fake.recorder.markAllCount, 1)
        XCTAssertTrue(store.notifications.isEmpty)
        XCTAssertNil(store.lastErrorMessage)
    }

    func testMarkAllReadFailureSetsErrorAndKeepsItems() async throws {
        var fake = FakeGitHubAPI()
        fake.notificationsResult = [.stub(id: "1"), .stub(id: "2")]
        struct Boom: Error {}
        fake.actionError = Boom()
        let store = try makeStore(api: fake)
        await store.refresh()

        await store.markAllRead()

        XCTAssertEqual(store.notifications.map(\.notification.id), ["1", "2"])
        XCTAssertNotNil(store.lastErrorMessage)
    }

    /// With the account filter scoped to one account, only that account's inbox is cleared and
    /// only its bulk endpoint is hit — the other account is left untouched.
    func testMarkAllReadRespectsAccountFilter() async throws {
        let urlA = try XCTUnwrap(URL(string: "https://api.github.com"))
        let urlB = try XCTUnwrap(URL(string: "https://ghe.example.com/api/v3"))
        var fakeA = FakeGitHubAPI()
        fakeA.notificationsResult = [.stub(id: "a1")]
        var fakeB = FakeGitHubAPI()
        fakeB.notificationsResult = [.stub(id: "b1")]
        let alice = Account(login: "alice", avatarURL: nil, kind: .oauth, apiBaseURL: urlA)
        let bob = Account(login: "bob", avatarURL: nil, kind: .personalAccessToken, apiBaseURL: urlB)
        let store = AppStore(
            apiBaseURL: urlA,
            accounts: [alice, bob],
            makeAPI: { [fakeA, fakeB] base, _ in base == urlB ? fakeB : fakeA }
        )
        await store.refresh()

        store.accountFilter = alice.id
        await store.markAllRead()

        XCTAssertEqual(fakeA.recorder.markAllCount, 1)
        XCTAssertEqual(fakeB.recorder.markAllCount, 0)
        XCTAssertEqual(store.notifications.map(\.notification.id), ["b1"])
        XCTAssertNil(store.lastErrorMessage)
    }

    // MARK: - Multi-account aggregation & filtering

    /// Two accounts on different hosts; `makeAPI` routes by base URL so each returns a
    /// distinct result set. The merged sections carry rows from both.
    private func makeTwoAccountStore() throws -> (AppStore, Account, Account) {
        let urlA = try XCTUnwrap(URL(string: "https://api.github.com"))
        let urlB = try XCTUnwrap(URL(string: "https://ghe.example.com/api/v3"))
        var fakeA = FakeGitHubAPI()
        fakeA.defaultResult = SearchIssue.stubs(count: 2)
        var fakeB = FakeGitHubAPI()
        fakeB.defaultResult = SearchIssue.stubs(count: 3)
        let alice = Account(login: "alice", avatarURL: nil, kind: .oauth, apiBaseURL: urlA)
        let bob = Account(login: "bob", avatarURL: nil, kind: .personalAccessToken, apiBaseURL: urlB)
        let store = AppStore(
            apiBaseURL: urlA,
            accounts: [alice, bob],
            makeAPI: { [fakeA, fakeB] base, _ in base == urlB ? fakeB : fakeA }
        )
        return (store, alice, bob)
    }

    func testRefreshAggregatesAcrossAccounts() async throws {
        let (store, _, _) = try makeTwoAccountStore()

        await store.refresh()

        // 3 PR sections + 1 issue section, each merges alice(2) + bob(3) = 5 rows.
        XCTAssertEqual(store.prSections.count, 3)
        XCTAssertEqual(store.prCount, 15)
        XCTAssertEqual(store.issueCount, 5)
        // Every PR section carries rows from both accounts.
        let logins = Set(store.prSections.flatMap(\.items).map(\.account.login))
        XCTAssertEqual(logins, ["alice", "bob"])
    }

    func testAccountFilterScopesCountsWithoutRefetch() async throws {
        let (store, _, _) = try makeTwoAccountStore()
        await store.refresh()

        XCTAssertEqual(store.prCount, 15) // All

        store.accountFilter = "alice"
        XCTAssertEqual(store.prCount, 6) // 3 sections × 2
        XCTAssertEqual(store.issueCount, 2)
        XCTAssertTrue(store.prSections.flatMap(\.items).allSatisfy { $0.account.login == "alice" })

        store.accountFilter = "bob"
        XCTAssertEqual(store.prCount, 9) // 3 sections × 3
        XCTAssertEqual(store.issueCount, 3)

        store.accountFilter = nil
        XCTAssertEqual(store.prCount, 15) // back to All
    }

    func testRemoveAccountDropsOnlyItsData() async throws {
        let (store, _, _) = try makeTwoAccountStore()
        await store.refresh()

        store.removeAccount(id: "bob")

        XCTAssertEqual(store.accounts.map(\.login), ["alice"])
        XCTAssertEqual(store.prCount, 6) // only alice's rows remain (3 × 2)
        XCTAssertTrue(store.sections.flatMap(\.items).allSatisfy { $0.account.login == "alice" })
    }

    func testRemovingLastAccountClearsPendingLegacyToken() throws {
        // A stale legacy token (e.g. migration never completed because it was revoked) plus one
        // real account. Removing the real account must not leave `isSignedIn` stuck true.
        let url = try makeURL()
        let alice = Account(login: "alice", avatarURL: nil, kind: .oauth, apiBaseURL: url)
        let fake = FakeGitHubAPI()
        let store = AppStore(apiBaseURL: url, accounts: [alice], makeAPI: { [fake] _, _ in fake })
        let box = TokenBox()
        store.deleteToken = { box.remove($0) }
        store.pendingLegacyTokenForTests = "legacy-token"
        XCTAssertTrue(store.isSignedIn)

        store.removeAccount(id: "alice")

        XCTAssertTrue(store.accounts.isEmpty)
        XCTAssertNil(store.pendingLegacyTokenForTests)
        XCTAssertFalse(store.isSignedIn)
    }

    // MARK: - Per-account reconnect (401 recovery)

    func testUnauthorizedTracksExpiredAccountAndAllowsReconnect() async throws {
        var fake = FakeGitHubAPI()
        fake.error = GitHubClient.ClientError.http(401)
        let account = try makeAccount(login: "octocat") // .oauth
        let store = try makeStore(api: fake, accounts: [account])
        store.oauthClientID = "public-client-id"

        await store.refresh()

        XCTAssertTrue(store.sessionExpired)
        XCTAssertEqual(store.expiredAccountID, "octocat")
        XCTAssertEqual(store.expiredAccount?.login, "octocat")
        XCTAssertTrue(store.canReconnect)
    }

    func testPATAccountCannotReconnectInPlace() async throws {
        var fake = FakeGitHubAPI()
        fake.error = GitHubClient.ClientError.http(401)
        let url = try makeURL()
        let pat = Account(login: "octocat", avatarURL: nil, kind: .personalAccessToken, apiBaseURL: url)
        let store = try makeStore(api: fake, accounts: [pat])
        store.oauthClientID = "public-client-id"

        await store.refresh()

        XCTAssertEqual(store.expiredAccountID, "octocat")
        // A PAT has no device flow to re-run, so reconnect-in-place is unavailable.
        XCTAssertFalse(store.canReconnect)
    }

    func testOAuthWithoutClientIDCannotReconnect() async throws {
        var fake = FakeGitHubAPI()
        fake.error = GitHubClient.ClientError.http(401)
        let account = try makeAccount(login: "octocat")
        let store = try makeStore(api: fake, accounts: [account])
        store.oauthClientID = "" // e.g. a self-host build with no baked/entered client ID

        await store.refresh()

        XCTAssertEqual(store.expiredAccountID, "octocat")
        XCTAssertFalse(store.canReconnect)
    }

    func testHealthyRefreshLeavesNoExpiredAccount() async throws {
        var fake = FakeGitHubAPI()
        fake.defaultResult = SearchIssue.stubs(count: 1)
        let store = try makeStore(api: fake)
        store.oauthClientID = "public-client-id"

        await store.refresh()

        XCTAssertFalse(store.sessionExpired)
        XCTAssertNil(store.expiredAccountID)
        XCTAssertNil(store.expiredAccount)
        XCTAssertFalse(store.canReconnect)
    }

    // MARK: - Legacy migration

    func testLegacyTokenMigratesToSingleAccount() async throws {
        let url = try makeURL()
        var fake = FakeGitHubAPI()
        fake.currentUserResult = GitHubUser(login: "legacyuser", avatarURL: nil)
        fake.defaultResult = SearchIssue.stubs(count: 1)
        let store = AppStore(apiBaseURL: url, accounts: [], makeAPI: { [fake] _, _ in fake })

        // Redirect token storage to an in-memory box so the Keychain isn't touched.
        let box = TokenBox()
        store.storeToken = { token, key in box.set(token, key) }
        store.deleteToken = { box.remove($0) }
        store.tokenForAccount = { box.get($0.keychainKey) }
        box.set("legacy-token", Credential.keychainKey)
        store.pendingLegacyTokenForTests = "legacy-token"

        // A pending legacy token counts as signed in even before it's resolved.
        XCTAssertTrue(store.isSignedIn)

        await store.refresh() // triggers migration first, then loads

        XCTAssertEqual(store.accounts.map(\.login), ["legacyuser"])
        XCTAssertEqual(store.accounts.first?.apiBaseURL, url)
        XCTAssertNil(store.pendingLegacyTokenForTests)
        // Re-keyed: legacy key gone, per-account key holds the token.
        XCTAssertNil(box.get(Credential.keychainKey))
        XCTAssertEqual(box.get(Account.keychainKeyPrefix + "legacyuser"), "legacy-token")
        // And it actually loaded after migrating.
        XCTAssertTrue(store.sections.contains { !$0.items.isEmpty })
    }

    func testLegacyMigrationIsIdempotent() async throws {
        let url = try makeURL()
        var fake = FakeGitHubAPI()
        fake.currentUserResult = GitHubUser(login: "legacyuser", avatarURL: nil)
        let store = AppStore(apiBaseURL: url, accounts: [], makeAPI: { [fake] _, _ in fake })
        let box = TokenBox()
        store.storeToken = { token, key in box.set(token, key) }
        store.deleteToken = { box.remove($0) }
        store.tokenForAccount = { box.get($0.keychainKey) }
        box.set("legacy-token", Credential.keychainKey)
        store.pendingLegacyTokenForTests = "legacy-token"

        await store.refresh()
        await store.refresh() // second pass must not duplicate the account

        XCTAssertEqual(store.accounts.map(\.login), ["legacyuser"])
    }

    /// A revoked legacy token (401 on `currentUser`) must be dropped so `isSignedIn` falls to false
    /// and the sign-in prompt takes over — not retried every poll behind a permanent skeleton.
    func testLegacyMigration401DropsTokenAndSurfacesSignIn() async throws {
        let url = try makeURL()
        let fake = FakeGitHubAPI(error: GitHubClient.ClientError.http(401))
        let store = AppStore(apiBaseURL: url, accounts: [], makeAPI: { _, _ in fake })
        let box = TokenBox()
        store.storeToken = { token, key in box.set(token, key) }
        store.deleteToken = { box.remove($0) }
        store.tokenForAccount = { box.get($0.keychainKey) }
        box.set("dead-token", Credential.keychainKey)
        store.pendingLegacyTokenForTests = "dead-token"
        XCTAssertTrue(store.isSignedIn)

        await store.refresh()

        XCTAssertFalse(store.isSignedIn)
        XCTAssertNil(store.pendingLegacyTokenForTests)
        XCTAssertNil(box.get(Credential.keychainKey))
        XCTAssertTrue(store.hasLoaded) // no permanent first-load skeleton
        XCTAssertNotNil(store.lastErrorMessage)
    }

    /// A transient (non-401) migration failure keeps the token staged for the next poll's retry.
    func testLegacyMigrationTransientFailureKeepsToken() async throws {
        struct Boom: Error {}
        let url = try makeURL()
        let fake = FakeGitHubAPI(error: Boom())
        let store = AppStore(apiBaseURL: url, accounts: [], makeAPI: { _, _ in fake })
        let box = TokenBox()
        store.storeToken = { token, key in box.set(token, key) }
        store.deleteToken = { box.remove($0) }
        store.tokenForAccount = { box.get($0.keychainKey) }
        box.set("legacy-token", Credential.keychainKey)
        store.pendingLegacyTokenForTests = "legacy-token"

        await store.refresh()

        XCTAssertEqual(store.pendingLegacyTokenForTests, "legacy-token")
        XCTAssertTrue(store.isSignedIn)
    }

    // MARK: - Rate limiting

    /// A rate-limited load records the reset time and surfaces the backoff message rather than a
    /// generic failure, and doesn't flag the session expired.
    func testRateLimitedLoadBacksOffAndSurfacesMessage() async throws {
        let reset = Date().addingTimeInterval(300)
        let fake = FakeGitHubAPI(error: GitHubClient.ClientError.rateLimited(until: reset))
        let store = try makeStore(api: fake)

        await store.refresh()

        let until = try XCTUnwrap(store.rateLimitedUntil)
        XCTAssertEqual(until.timeIntervalSince1970, reset.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(store.lastErrorMessage, AuthErrorCopy.rateLimitMessage(until: reset))
        XCTAssertFalse(store.sessionExpired)
    }

    /// When only the inbox is rate-limited, the sections that loaded still show — the limit only
    /// drives the backoff and message.
    func testPartialRateLimitKeepsLoadedSections() async throws {
        let reset = Date().addingTimeInterval(120)
        var fake = FakeGitHubAPI()
        fake.defaultResult = SearchIssue.stubs(count: 2)
        fake.notificationsError = GitHubClient.ClientError.rateLimited(until: reset)
        let store = try makeStore(api: fake)

        await store.refresh()
        await store.awaitChecksHydration()

        XCTAssertTrue(store.sections.contains { !$0.items.isEmpty })
        XCTAssertNotNil(store.rateLimitedUntil)
        XCTAssertFalse(store.sessionExpired)
        // The request-heavy CI/repo-feed hydration (N+1 over the PR list) is skipped while limited.
        XCTAssertEqual(fake.recorder.pullRequestCount, 0)
    }

    /// A PR unchanged since the last poll (same `updated_at`) skips the detail+reviews refetch —
    /// its gate is still current — but its check-runs are still re-read, because CI can flip on a
    /// re-run of the same commit without bumping `updated_at`. This is the idle-inbox N+1 cut.
    func testUnchangedPRSkipsDetailButStillPollsChecks() async throws {
        let ts = Date()
        var fake = FakeGitHubAPI()
        fake.defaultResult = [SearchIssue.stub(id: 100, number: 7, updatedAt: ts)]
        // Not-yet-mergeable (blocked) so it's skip-eligible — a mergeable PR is deliberately never
        // skipped (see `testMergeablePRIsNotSkipped`).
        fake.pullRequestResult = .stub(number: 7, headSHA: "deadbeef", mergeableState: "blocked")
        fake.checkRunsResult = [.stub(id: 1, name: "CI", conclusion: "success")]
        let store = try makeStore(api: fake)
        store.useGraphQLBatch = false // the updated_at short-circuit is a REST-path optimization

        await store.refresh()
        await store.awaitChecksHydration()
        let detailAfterSeed = fake.recorder.pullRequestCount
        let checksAfterSeed = fake.recorder.checkRunsCount
        XCTAssertEqual(detailAfterSeed, 1, "seed poll fetches the detail once")

        // Second poll, identical `updated_at`.
        await store.refresh()
        await store.awaitChecksHydration()
        XCTAssertEqual(fake.recorder.pullRequestCount, detailAfterSeed, "unchanged PR must not refetch detail/reviews")
        XCTAssertGreaterThan(
            fake.recorder.checkRunsCount,
            checksAfterSeed,
            "check-runs must still be polled on the skip"
        )
    }

    /// When a PR's `updated_at` advances, the skip does not apply — the detail is refetched so the
    /// gate (mergeable/approved) re-derives against the new state.
    func testAdvancedUpdatedAtRefetchesDetail() async throws {
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        var seed = FakeGitHubAPI()
        seed.defaultResult = [SearchIssue.stub(id: 100, number: 7, updatedAt: old)]
        seed.pullRequestResult = .stub(number: 7, headSHA: "deadbeef", mergeableState: "blocked")
        seed.checkRunsResult = [.stub(id: 1, name: "CI", conclusion: "success")]
        let store = try makeStore(api: seed)
        store.useGraphQLBatch = false // the updated_at short-circuit is a REST-path optimization

        await store.refresh()
        await store.awaitChecksHydration()
        XCTAssertEqual(seed.recorder.pullRequestCount, 1)

        var next = FakeGitHubAPI()
        next.defaultResult = [SearchIssue.stub(id: 100, number: 7, updatedAt: old.addingTimeInterval(3600))]
        next.pullRequestResult = .stub(number: 7, headSHA: "deadbeef", mergeableState: "blocked")
        next.checkRunsResult = [.stub(id: 1, name: "CI", conclusion: "success")]
        store.makeAPI = { [next] _, _ in next }

        await store.refresh()
        await store.awaitChecksHydration()
        // A fresh fake → its own recorder; a full refetch means the detail was fetched on it.
        XCTAssertEqual(next.recorder.pullRequestCount, 1, "an advanced updated_at must trigger a full refetch")
    }

    /// A PR whose Merge button is showing (`gate.mergeable`) is never skipped, even when unchanged:
    /// a base-branch advance can flip its `mergeable_state` to behind/dirty without bumping
    /// `updated_at`, and a stale Merge button would 405 on click. So it's always refetched.
    func testMergeablePRIsNotSkipped() async throws {
        let ts = Date()
        var fake = FakeGitHubAPI()
        fake.defaultResult = [SearchIssue.stub(id: 100, number: 7, updatedAt: ts)]
        fake.pullRequestResult = .stub(number: 7, headSHA: "deadbeef", mergeableState: "clean")
        fake.repositoryResult = .stub(push: true)
        let store = try makeStore(api: fake)
        store.useGraphQLBatch = false // the updated_at short-circuit is a REST-path optimization

        await store.refresh()
        await store.awaitChecksHydration()
        let detailAfterSeed = fake.recorder.pullRequestCount
        let pr = try XCTUnwrap(store.prSections.flatMap(\.items).first { $0.issue.number == 7 })
        XCTAssertEqual(store.gate(for: pr)?.mergeable, true, "precondition: the PR is mergeable")

        await store.refresh()
        await store.awaitChecksHydration()
        XCTAssertGreaterThan(
            fake.recorder.pullRequestCount, detailAfterSeed, "a mergeable PR must be refetched, not skipped"
        )
    }

    func testPollDelayHonorsRateLimitAndCadenceFloor() {
        let now = Date()
        // A future reset past the cadence wins.
        XCTAssertEqual(
            AppStore.pollDelay(pollInterval: 60, rateLimitedUntil: now.addingTimeInterval(300), now: now),
            300, accuracy: 0.01
        )
        // A reset sooner than the cadence floors at the cadence.
        XCTAssertEqual(
            AppStore.pollDelay(pollInterval: 60, rateLimitedUntil: now.addingTimeInterval(10), now: now),
            60, accuracy: 0.01
        )
        // A past reset and a nil reset both degrade to the plain cadence.
        XCTAssertEqual(
            AppStore.pollDelay(pollInterval: 60, rateLimitedUntil: now.addingTimeInterval(-100), now: now),
            60, accuracy: 0.01
        )
        XCTAssertEqual(AppStore.pollDelay(pollInterval: 60, rateLimitedUntil: nil, now: now), 60, accuracy: 0.01)
    }

    /// A clean poll after a rate limit clears the backoff and its message.
    func testRecoveredPollClearsRateLimit() async throws {
        let reset = Date().addingTimeInterval(120)
        let limited = FakeGitHubAPI(error: GitHubClient.ClientError.rateLimited(until: reset))
        let store = try makeStore(api: limited)
        await store.refresh()
        XCTAssertNotNil(store.rateLimitedUntil)

        store.makeAPI = { _, _ in FakeGitHubAPI() }
        await store.refresh(force: true)

        XCTAssertNil(store.rateLimitedUntil)
        XCTAssertNil(store.lastErrorMessage)
    }

    // MARK: - Notification mutator auth

    /// A 401 marking one thread read flags the session expired (matching the quick-action path),
    /// keeps the item, and offers a reconnect instead of a dead-end failure.
    func testMarkReadUnauthorizedFlagsSessionExpired() async throws {
        var fake = FakeGitHubAPI()
        fake.notificationsResult = [.stub(id: "1")]
        let store = try makeStore(api: fake)
        await store.refresh()

        store.makeAPI = { _, _ in FakeGitHubAPI(error: GitHubClient.ClientError.http(401)) }
        let target = try XCTUnwrap(store.notifications.first)
        await store.markRead(target)

        XCTAssertTrue(store.sessionExpired)
        XCTAssertEqual(store.expiredAccount?.login, "octocat")
        XCTAssertEqual(store.notifications.map(\.notification.id), ["1"])
    }

    /// A 401 from the bulk mark-all endpoint likewise flags the session expired and keeps the inbox.
    func testMarkAllReadUnauthorizedFlagsSessionExpired() async throws {
        var fake = FakeGitHubAPI()
        fake.notificationsResult = [.stub(id: "1"), .stub(id: "2")]
        fake.actionError = GitHubClient.ClientError.http(401)
        let store = try makeStore(api: fake)
        await store.refresh()

        await store.markAllRead()

        XCTAssertTrue(store.sessionExpired)
        XCTAssertEqual(store.notifications.count, 2)
    }

    // MARK: - Starred signal

    func testRefreshMergesStarredAndIsStarredIsCaseInsensitive() async throws {
        var fake = FakeGitHubAPI()
        // GitHub preserves owner/name casing; membership must be case-insensitive.
        fake.starredResult = ["Octo/Repo"]
        let store = try makeStore(api: fake)

        await store.refresh()

        let starred = try item(SearchIssue.stub(id: 1)) // repositorySlug == "octo/repo"
        XCTAssertTrue(store.isStarred(starred))
        // A repo the account hasn't starred isn't marked.
        let notStarred = try AccountItem(account: makeAccount(), issue: SearchIssue.stub(id: 2, repo: "other/repo"))
        XCTAssertFalse(store.isStarred(notStarred))
    }

    func testStarredFetchFailureKeepsPriorSet() async throws {
        var fake = FakeGitHubAPI()
        fake.starredResult = ["octo/repo"]
        let store = try makeStore(api: fake)
        await store.refresh()
        XCTAssertTrue(try store.isStarred(item(SearchIssue.stub(id: 1))))

        // A later poll where only the starred fetch fails must not wipe the set (and must not
        // surface an error message — starred isn't a section the user asked for).
        struct Boom: Error {}
        var flaky = FakeGitHubAPI()
        flaky.starredError = Boom()
        store.makeAPI = { [flaky] _, _ in flaky }
        await store.refresh(force: true)

        XCTAssertTrue(try store.isStarred(item(SearchIssue.stub(id: 1))))
        XCTAssertNil(store.lastErrorMessage)
        XCTAssertFalse(store.sessionExpired)
    }

    // MARK: - Watchlist / repo set

    func testWatchedRepoRefsFromWatchlistDedupsAndSkipsBlank() throws {
        let fake = FakeGitHubAPI()
        let store = try makeStore(api: fake)
        store.watchlist = ["  octo/repo  ", "octo/repo", "malformed", "", "owner/name"]
        let account = try makeAccount()
        let refs = store.watchedRepoRefs(apis: [account.id: fake])

        // Trimmed + deduped ("octo/repo" once), blank/malformed skipped.
        XCTAssertEqual(refs.map(\.slug), ["octo/repo", "owner/name"])
        XCTAssertTrue(refs.allSatisfy { $0.account.id == account.id })
    }

    func testWatchedRepoRefsCapsTotalFanOut() throws {
        let fake = FakeGitHubAPI()
        let store = try makeStore(api: fake)
        store.watchlist = (0..<(AppStore.reposScanCap + 10)).map { "octo/repo\($0)" }
        let account = try makeAccount()
        let refs = store.watchedRepoRefs(apis: [account.id: fake])
        XCTAssertEqual(refs.count, AppStore.reposScanCap)
    }

    func testNormalizedSlugValidation() {
        XCTAssertEqual(AppStore.normalizedSlug("  octo/repo "), "octo/repo")
        XCTAssertNil(AppStore.normalizedSlug(""))
        XCTAssertNil(AppStore.normalizedSlug("noslash"))
        XCTAssertNil(AppStore.normalizedSlug("a/b/c"))
        XCTAssertNil(AppStore.normalizedSlug("/repo"))
        XCTAssertNil(AppStore.normalizedSlug("owner/"))
        // Interior whitespace is a typo, not a repo path.
        XCTAssertNil(AppStore.normalizedSlug("own er/repo"))
        XCTAssertNil(AppStore.normalizedSlug("owner/ "))
        // Path-traversal segments are rejected so a slug can't rewrite the request path (these are
        // valid 2-component slugs that only the new `.`/`..` guard rejects).
        XCTAssertNil(AppStore.normalizedSlug("../foo"))
        XCTAssertNil(AppStore.normalizedSlug("owner/.."))
        XCTAssertNil(AppStore.normalizedSlug("../repo"))
        // A repo name containing dots (but not a bare `..`) is still valid.
        XCTAssertEqual(AppStore.normalizedSlug("owner/repo.js"), "owner/repo.js")
    }

    // MARK: - Repo feeds hydration

    func testHydrateRepoFeedsPopulatesAndSortsNewestFirst() async throws {
        var fake = FakeGitHubAPI()
        fake.workflowRunsResult = [
            .stub(id: 1, updatedAt: "2026-01-01T00:00:00Z"),
            .stub(id: 2, updatedAt: "2026-01-02T00:00:00Z"),
        ]
        fake.releasesResult = [
            .stub(id: 10, tagName: "v1.0.0", publishedAt: "2026-01-01T00:00:00Z"),
            .stub(id: 11, tagName: "v1.1.0", publishedAt: "2026-01-03T00:00:00Z"),
        ]
        let store = try makeStore(api: fake)
        store.watchlist = ["octo/repo"]

        await store.refresh()
        await store.awaitRepoFeedsHydration()

        XCTAssertTrue(store.hasLoadedRepoFeeds)
        XCTAssertEqual(store.actionRuns.map(\.run.id), [2, 1]) // newest first
        XCTAssertEqual(store.releases.map(\.release.id), [11, 10])
        XCTAssertTrue(store.actionRuns.allSatisfy { $0.repo == "octo/repo" })
    }

    func testHydrateRepoFeedsDropsDraftReleases() async throws {
        var fake = FakeGitHubAPI()
        fake.releasesResult = [
            .stub(id: 10, tagName: "v1.0.0", publishedAt: "2026-01-01T00:00:00Z", draft: false),
            .stub(id: 11, tagName: "draft", publishedAt: nil, draft: true),
        ]
        let store = try makeStore(api: fake)
        store.watchlist = ["octo/repo"]

        await store.refresh()
        await store.awaitRepoFeedsHydration()

        XCTAssertEqual(store.releases.map(\.release.id), [10])
    }

    func testEmptyWatchlistClearsFeedsAndMarksLoaded() async throws {
        let fake = FakeGitHubAPI()
        let store = try makeStore(api: fake)
        // watchlist defaults to empty in the test init.

        await store.refresh()
        await store.awaitRepoFeedsHydration()

        XCTAssertTrue(store.actionRuns.isEmpty)
        XCTAssertTrue(store.releases.isEmpty)
        XCTAssertTrue(store.hasLoadedRepoFeeds)
    }

    func testActionRunsAttentionCountCountsFailingAndRunning() async throws {
        var fake = FakeGitHubAPI()
        fake.workflowRunsResult = [
            .stub(id: 1, status: "completed", conclusion: "success"),
            .stub(id: 2, status: "completed", conclusion: "failure"),
            .stub(id: 3, status: "in_progress", conclusion: nil),
        ]
        let store = try makeStore(api: fake)
        store.watchlist = ["octo/repo"]

        await store.refresh()
        await store.awaitRepoFeedsHydration()

        XCTAssertEqual(store.actionRunsAttentionCount, 2) // failure + running
    }

    func testRemoveAccountPrunesFeedsAndStarred() async throws {
        var fake = FakeGitHubAPI()
        fake.starredResult = ["octo/repo"]
        fake.workflowRunsResult = [.stub(id: 1)]
        fake.releasesResult = [.stub(id: 10)]
        let account = try makeAccount()
        let store = try makeStore(api: fake, accounts: [account])
        store.watchlist = ["octo/repo"]

        await store.refresh()
        await store.awaitRepoFeedsHydration()
        XCTAssertFalse(store.actionRuns.isEmpty)
        XCTAssertTrue(try store.isStarred(item(SearchIssue.stub(id: 1))))

        store.removeAccount(id: account.id)

        XCTAssertTrue(store.actionRuns.isEmpty)
        XCTAssertTrue(store.releases.isEmpty)
        XCTAssertFalse(try store.isStarred(item(SearchIssue.stub(id: 1))))
    }
}

/// In-memory token store so migration/account tests can inject `AppStore`'s Keychain hooks
/// without touching the real Keychain. Lock-guarded because the closures are `@Sendable`.
private final class TokenBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String] = [:]

    func get(_ key: String) -> String? {
        lock.withLock { storage[key] }
    }

    func set(_ value: String, _ key: String) {
        lock.withLock { storage[key] = value }
    }

    func remove(_ key: String) {
        lock.withLock { storage[key] = nil }
    }
}
