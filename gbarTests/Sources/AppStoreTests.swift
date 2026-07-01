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
