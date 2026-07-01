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
}
