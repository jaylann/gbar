import XCTest
@testable import gbar

/// Records `post` calls so tests can assert the store fires the right banners without touching
/// `UNUserNotificationCenter`.
@MainActor
final class SpyNotifier: DesktopNotifying {
    struct Post: Equatable {
        let title: String
        let body: String
        let url: URL?
    }

    private(set) var posts: [Post] = []

    func post(title: String, body: String, url: URL?) {
        posts.append(Post(title: title, body: body, url: url))
    }
}

private struct Boom: Error {}

@MainActor
final class AppStoreNotificationTests: XCTestCase {
    private func makeAccount(login: String = "octocat", host: String = "https://api.github.com") throws -> Account {
        try Account(login: login, avatarURL: nil, kind: .oauth, apiBaseURL: XCTUnwrap(URL(string: host)))
    }

    private func makeStore(api: FakeGitHubAPI, accounts: [Account]? = nil) throws -> AppStore {
        let url = try XCTUnwrap(URL(string: "https://api.github.com"))
        let accts = try accounts ?? [makeAccount()]
        return AppStore(apiBaseURL: url, accounts: accts, makeAPI: { _, _ in api })
    }

    private func key(_ prID: Int, account: String = "octocat") -> PRCheckKey {
        PRCheckKey(accountID: account, prID: prID)
    }

    // MARK: - Sections

    func testFirstRefreshSeedsSectionBaselineWithoutNotifying() async throws {
        var fake = FakeGitHubAPI()
        fake.defaultResult = [SearchIssue.stub(id: 1, number: 1)]
        let store = try makeStore(api: fake)
        let spy = SpyNotifier()
        store.notifier = spy

        await store.refresh()

        XCTAssertTrue(spy.posts.isEmpty, "the seeding poll must not notify for pre-existing items")
    }

    func testSecondRefreshNotifiesForNewSectionItem() async throws {
        var seed = FakeGitHubAPI()
        seed.defaultResult = [SearchIssue.stub(id: 1, number: 1)]
        let store = try makeStore(api: seed)
        let spy = SpyNotifier()
        store.notifier = spy
        await store.refresh() // seed

        var next = FakeGitHubAPI()
        next.defaultResult = [SearchIssue.stub(id: 1, number: 1), SearchIssue.stub(id: 2, number: 2)]
        store.makeAPI = { [next] _, _ in next }
        await store.refresh()

        // id 2 is new; id 1 was already seeded. Deduped to a single banner despite appearing in
        // every default section.
        XCTAssertEqual(spy.posts.count, 1)
        XCTAssertTrue(spy.posts[0].body.contains("#2"))
    }

    func testSectionToggleOffSuppressesNotification() async throws {
        var seed = FakeGitHubAPI()
        seed.defaultResult = [SearchIssue.stub(id: 1, number: 1)]
        let store = try makeStore(api: seed)
        let spy = SpyNotifier()
        store.notifier = spy
        store.notifySections = false
        await store.refresh() // seed

        var next = FakeGitHubAPI()
        next.defaultResult = [SearchIssue.stub(id: 1, number: 1), SearchIssue.stub(id: 2, number: 2)]
        store.makeAPI = { [next] _, _ in next }
        await store.refresh()

        XCTAssertTrue(spy.posts.isEmpty)
    }

    func testMasterToggleOffSuppressesAllNotifications() async throws {
        var seed = FakeGitHubAPI()
        seed.defaultResult = [SearchIssue.stub(id: 1, number: 1)]
        let store = try makeStore(api: seed)
        let spy = SpyNotifier()
        store.notifier = spy
        store.notificationsEnabled = false
        await store.refresh() // seed

        var next = FakeGitHubAPI()
        next.defaultResult = [SearchIssue.stub(id: 1, number: 1), SearchIssue.stub(id: 2, number: 2)]
        store.makeAPI = { [next] _, _ in next }
        await store.refresh()

        XCTAssertTrue(spy.posts.isEmpty)
    }

    /// Two accounts return an item with the same numeric id; the composite baseline key keeps
    /// them distinct, so a new item on one account doesn't get masked by the other's baseline.
    func testNewSectionItemsAreAccountScoped() async throws {
        let urlA = try XCTUnwrap(URL(string: "https://api.github.com"))
        let urlB = try XCTUnwrap(URL(string: "https://ghe.example.com/api/v3"))
        let alice = try makeAccount(login: "alice", host: urlA.absoluteString)
        let bob = try makeAccount(login: "bob", host: urlB.absoluteString)
        var fakeA = FakeGitHubAPI()
        fakeA.defaultResult = [SearchIssue.stub(id: 1, number: 1)]
        var fakeB = FakeGitHubAPI()
        fakeB.defaultResult = [SearchIssue.stub(id: 1, number: 1)]
        let store = AppStore(
            apiBaseURL: urlA,
            accounts: [alice, bob],
            makeAPI: { [fakeA, fakeB] base, _ in base == urlB ? fakeB : fakeA }
        )
        let spy = SpyNotifier()
        store.notifier = spy
        await store.refresh() // seed both accounts

        // bob gains a new item id 2; alice unchanged. Only one banner, tagged for bob's host.
        fakeB.defaultResult = [SearchIssue.stub(id: 1, number: 1), SearchIssue.stub(id: 2, number: 2)]
        store.makeAPI = { [fakeA, fakeB] base, _ in base == urlB ? fakeB : fakeA }
        await store.refresh()

        XCTAssertEqual(spy.posts.count, 1)
        XCTAssertTrue(spy.posts[0].body.contains("#2"))
    }

    // MARK: - Inbox

    func testSecondRefreshNotifiesForNewInboxItem() async throws {
        var seed = FakeGitHubAPI()
        seed.notificationsResult = [.stub(id: "1")]
        let store = try makeStore(api: seed)
        let spy = SpyNotifier()
        store.notifier = spy
        await store.refresh() // seed

        var next = FakeGitHubAPI()
        next.notificationsResult = [.stub(id: "1"), .stub(id: "2", title: "Fresh thread")]
        store.makeAPI = { [next] _, _ in next }
        await store.refresh()

        XCTAssertEqual(spy.posts.count, 1)
        XCTAssertEqual(spy.posts[0].body, "Fresh thread")
    }

    // MARK: - CI checks

    func testCheckStatusFlipNotifies() async throws {
        var seed = FakeGitHubAPI()
        seed.defaultResult = [SearchIssue.stub(id: 100, number: 7)]
        seed.pullRequestResult = .stub(number: 7, headSHA: "deadbeef")
        seed.checkRunsResult = [.stub(id: 1, name: "CI", conclusion: "success")]
        let store = try makeStore(api: seed)
        let spy = SpyNotifier()
        store.notifier = spy

        await store.refresh() // seed: first CI observation stays quiet
        await store.awaitChecksHydration()
        XCTAssertTrue(spy.posts.isEmpty)

        // CI now fails on the same PR — expect a "CI failed" banner.
        var next = FakeGitHubAPI()
        next.defaultResult = [SearchIssue.stub(id: 100, number: 7)]
        next.pullRequestResult = .stub(number: 7, headSHA: "deadbeef")
        next.checkRunsResult = [.stub(id: 1, name: "CI", conclusion: "failure")]
        store.makeAPI = { [next] _, _ in next }
        await store.refresh()
        await store.awaitChecksHydration()

        XCTAssertEqual(spy.posts.count, 1)
        XCTAssertEqual(spy.posts[0].title, "CI failed")
        XCTAssertTrue(spy.posts[0].body.contains("#7"))
    }

    // MARK: - Bug regressions

    /// Bug #1: a first poll that fails entirely must NOT seed the baseline. The first *successful*
    /// poll after that still seeds silently, so it can't spam a banner per pre-existing item.
    func testFailedFirstPollDoesNotSeedSoRecoveryStaysSilent() async throws {
        let failing = FakeGitHubAPI(error: Boom())
        let store = try makeStore(api: failing)
        let spy = SpyNotifier()
        store.notifier = spy

        await store.refresh() // total failure: must not seed
        XCTAssertTrue(spy.posts.isEmpty)

        var recovered = FakeGitHubAPI()
        recovered.defaultResult = [SearchIssue.stub(id: 1, number: 1)]
        recovered.notificationsResult = [.stub(id: "n1")]
        store.makeAPI = { [recovered] _, _ in recovered }
        await store.refresh() // first successful poll: seeds silently, no spam
        XCTAssertTrue(spy.posts.isEmpty, "recovery after a failed first poll must seed silently, not spam")

        var next = FakeGitHubAPI()
        next.defaultResult = [SearchIssue.stub(id: 1, number: 1), SearchIssue.stub(id: 2, number: 2)]
        next.notificationsResult = [.stub(id: "n1")]
        store.makeAPI = { [next] _, _ in next }
        await store.refresh() // now a genuinely new item notifies
        XCTAssertEqual(spy.posts.count, 1)
        XCTAssertTrue(spy.posts[0].body.contains("#2"))
    }

    /// Bug #2: a section that fails a poll must keep its baseline, so its pre-existing items don't
    /// re-fire as "new" when the section recovers.
    func testSectionFailureDoesNotReplayItemsOnRecovery() async throws {
        var seed = FakeGitHubAPI()
        seed.defaultResult = [SearchIssue.stub(id: 1, number: 1)]
        let store = try makeStore(api: seed)
        let spy = SpyNotifier()
        store.notifier = spy
        await store.refresh() // seed
        XCTAssertTrue(spy.posts.isEmpty)

        // Transient failure: the section comes back empty-because-failed.
        let failing = FakeGitHubAPI(error: Boom())
        store.makeAPI = { [failing] _, _ in failing }
        await store.refresh()
        XCTAssertTrue(spy.posts.isEmpty)

        // Recovery with the same pre-existing item — must NOT re-notify.
        store.makeAPI = { [seed] _, _ in seed }
        await store.refresh()
        XCTAssertTrue(spy.posts.isEmpty, "a recovered section must not replay its pre-existing items")
    }

    /// Bug #3: a transient CI-fetch failure must not wipe the baseline, else the next real pass→fail
    /// transition (seen as `previous == nil`) would be swallowed.
    func testTransientCIFailureDoesNotSwallowLaterFlip() async throws {
        var seed = FakeGitHubAPI()
        seed.defaultResult = [SearchIssue.stub(id: 100, number: 7)]
        seed.pullRequestResult = .stub(number: 7, headSHA: "deadbeef")
        seed.checkRunsResult = [.stub(id: 1, name: "CI", conclusion: "success")]
        let store = try makeStore(api: seed)
        let spy = SpyNotifier()
        store.notifier = spy

        await store.refresh() // seed: success observed
        await store.awaitChecksHydration()
        XCTAssertTrue(spy.posts.isEmpty)

        // The PR still loads, but its CI fetch errors this poll → baseline must be preserved.
        var flaky = FakeGitHubAPI()
        flaky.defaultResult = [SearchIssue.stub(id: 100, number: 7)]
        flaky.pullRequestResult = .stub(number: 7, headSHA: "deadbeef")
        flaky.checkRunsError = Boom()
        store.makeAPI = { [flaky] _, _ in flaky }
        await store.refresh()
        await store.awaitChecksHydration()
        XCTAssertTrue(spy.posts.isEmpty)
        // The decorative dot is cleared, but the baseline still remembers success.
        XCTAssertNil(store.prChecks[key(100)])

        // CI now genuinely fails — the flip must still be detected (not swallowed).
        var failing = FakeGitHubAPI()
        failing.defaultResult = [SearchIssue.stub(id: 100, number: 7)]
        failing.pullRequestResult = .stub(number: 7, headSHA: "deadbeef")
        failing.checkRunsResult = [.stub(id: 1, name: "CI", conclusion: "failure")]
        store.makeAPI = { [failing] _, _ in failing }
        await store.refresh()
        await store.awaitChecksHydration()

        XCTAssertEqual(spy.posts.count, 1)
        XCTAssertEqual(spy.posts[0].title, "CI failed")
    }

    /// Sign-out resets the baselines, so the next sign-in seeds silently instead of spamming.
    func testSignOutResetsBaselinesSoNextSessionSeedsSilently() async throws {
        var fake = FakeGitHubAPI()
        fake.defaultResult = [SearchIssue.stub(id: 1, number: 1)]
        let account = try makeAccount()
        let store = try makeStore(api: fake, accounts: [account])
        // Keep the Keychain out of it — token I/O is redirected to no-op/constant closures.
        store.storeToken = { _, _ in }
        store.deleteToken = { _ in }
        store.tokenForAccount = { _ in "test-token" }
        let spy = SpyNotifier()
        store.notifier = spy
        await store.refresh() // seed
        XCTAssertTrue(spy.posts.isEmpty)

        store.signOutAll()

        // Reconnect the same account (addAccount runs a refresh) — the first post-reconnect poll
        // must seed silently, not fire a banner for the pre-existing item.
        try await store.addAccount(
            token: "test-token",
            kind: .oauth,
            apiBaseURL: XCTUnwrap(URL(string: "https://api.github.com"))
        )

        XCTAssertTrue(spy.posts.isEmpty, "a fresh session must seed silently after sign-out")
    }
}
