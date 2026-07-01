import XCTest
@testable import gbar

@MainActor
final class AppStoreTests: XCTestCase {
    private func makeURL() throws -> URL {
        try XCTUnwrap(URL(string: "https://api.github.com"))
    }

    private func makeStore(api: FakeGitHubAPI) throws -> AppStore {
        let url = try makeURL()
        return AppStore(
            apiBaseURL: url,
            credential: Credential(kind: .oauth, token: "test-token"),
            makeAPI: { _, _ in api }
        )
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

    // MARK: - Quick actions

    func testApproveRecordsCallOnHappyPath() async throws {
        let fake = FakeGitHubAPI()
        let store = try makeStore(api: fake)
        let pr = SearchIssue.stub(id: 1, number: 42)

        await store.approve(pr)

        XCTAssertEqual(fake.recorder.approvals, [.init(repo: "octo/repo", number: 42)])
        XCTAssertNil(store.lastErrorMessage)
    }

    func testApproveErrorSetsMessage() async throws {
        struct Boom: Error {}
        var fake = FakeGitHubAPI()
        fake.error = Boom()
        let store = try makeStore(api: fake)

        await store.approve(SearchIssue.stub(id: 1, number: 42))

        XCTAssertEqual(fake.recorder.approvals.count, 1)
        XCTAssertNotNil(store.lastErrorMessage)
    }

    func testMergeRecordsCallAndRemovesItemOptimistically() async throws {
        var fake = FakeGitHubAPI()
        fake.defaultResult = SearchIssue.stubs(count: 2) // ids/numbers 0 and 1
        let store = try makeStore(api: fake)
        await store.refresh()
        let target = try XCTUnwrap(store.sections.first?.items.first) // id 0

        await store.merge(target, method: .squash)

        XCTAssertEqual(fake.recorder.merges, [.init(repo: "octo/repo", number: target.number, method: .squash)])
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

        await store.merge(SearchIssue.stub(id: 7, number: 7), method: .merge)

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

        await store.merge(SearchIssue.stub(id: 1, number: 42), method: .merge)

        XCTAssertTrue(store.sessionExpired)
        XCTAssertEqual(store.lastErrorMessage, "Session expired — reconnect in Settings.")
    }

    func testApproveUnauthorizedSetsSessionExpired() async throws {
        var fake = FakeGitHubAPI()
        fake.error = GitHubClient.ClientError.http(401)
        let store = try makeStore(api: fake)

        await store.approve(SearchIssue.stub(id: 1, number: 42))

        XCTAssertTrue(store.sessionExpired)
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
        try await waitUntil { store.prChecks[100] != nil }

        let checks = try XCTUnwrap(store.prChecks[100])
        XCTAssertEqual(checks.status, .failure) // failure dominates the rollup
        XCTAssertEqual(checks.checks.count, 2)
        XCTAssertEqual(checks.checks.first?.branch, "feature/ci") // branch = head ref, not SHA
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

        XCTAssertNil(store.prChecks[200])
    }

    func testRefreshPrunesPRThatDroppedOutOfList() async throws {
        var fake = FakeGitHubAPI()
        fake.defaultResult = [SearchIssue.stub(id: 100, number: 7)]
        fake.pullRequestResult = .stub(number: 7)
        fake.checkRunsResult = [.stub(id: 1, conclusion: "success")]
        let store = try makeStore(api: fake)

        await store.refresh()
        try await waitUntil { store.prChecks[100] != nil }

        // Next refresh returns no PRs — the previous entry must be pruned, not linger.
        let empty = FakeGitHubAPI() // defaultResult is [] by default
        store.makeAPI = { _, _ in empty }
        await store.refresh()

        // Pruning happens synchronously at the start of the hydration wave.
        XCTAssertNil(store.prChecks[100])
        XCTAssertTrue(store.prChecks.isEmpty)
    }

    func testSignOutCancelsHydrationSoPRChecksStayEmpty() async throws {
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
        store.signOut()
        // Let the parked call finish; the stale-generation guard must drop its result.
        await gated.release()
        await wave?.value

        XCTAssertTrue(store.prChecks.isEmpty)
        XCTAssertNil(store.prChecks[300])
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

    func testBadgeCountSumsOnlyActionableSections() async throws {
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

        // Only review-requested (3) + assigned-prs (2) count toward the badge.
        XCTAssertEqual(store.badgeCount, 5)
    }

    func testRefreshLoadsNotifications() async throws {
        var fake = FakeGitHubAPI()
        fake.notificationsResult = [
            .stub(id: "1", title: "First"),
            .stub(id: "2", title: "Second"),
        ]
        let store = try makeStore(api: fake)

        await store.refresh()

        XCTAssertEqual(store.notifications.map(\.id), ["1", "2"])
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

        let target = try XCTUnwrap(store.notifications.first { $0.id == "1" })
        await store.markRead(target)

        XCTAssertEqual(fake.recorder.markedThreadIDs, ["1"])
        XCTAssertEqual(store.notifications.map(\.id), ["2"])
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

        XCTAssertEqual(store.notifications.map(\.id), ["1"])
        XCTAssertNotNil(store.lastErrorMessage)
    }
}
