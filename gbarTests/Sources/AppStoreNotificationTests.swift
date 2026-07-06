import UserNotifications
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
    var stubbedAuthStatus: NotificationAuthStatus = .authorized
    private(set) var authorizationRequests = 0

    func post(title: String, body: String, url: URL?) {
        posts.append(Post(title: title, body: body, url: url))
    }

    func requestAuthorization() async -> Bool {
        authorizationRequests += 1
        return stubbedAuthStatus == .authorized
    }

    func authorizationStatus() async -> NotificationAuthStatus {
        stubbedAuthStatus
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

    /// A dormant item that was absent last poll and churns back into the capped/eventually-
    /// consistent search window must NOT re-fire a banner — the recency gate suppresses anything
    /// last active beyond the window even though the baseline diff considers it "unseen".
    func testStaleSectionItemChurningInDoesNotNotify() async throws {
        var seed = FakeGitHubAPI()
        seed.defaultResult = [SearchIssue.stub(id: 1, number: 1)]
        let store = try makeStore(api: seed)
        let spy = SpyNotifier()
        store.notifier = spy
        await store.refresh() // seed (item 1 only)

        // Item 99 appears now but was last updated ~9 months ago (like a long-forgotten open PR).
        var next = FakeGitHubAPI()
        next.defaultResult = [
            SearchIssue.stub(id: 1, number: 1),
            SearchIssue.stub(id: 99, number: 99, updatedAt: Date(timeIntervalSinceNow: -270 * 24 * 60 * 60)),
        ]
        store.makeAPI = { [next] _, _ in next }
        await store.refresh()

        XCTAssertTrue(spy.posts.isEmpty, "a months-old item must not banner even when newly in-window")
    }

    /// After a long gap with no successful poll (system sleep, outage, notifications toggled off),
    /// an item that is genuinely new to us but whose activity predates the gap must still banner —
    /// the recency gate is skipped because the last poll wasn't recent.
    func testLongPollingGapBypassesRecencyGate() async throws {
        var seed = FakeGitHubAPI()
        seed.defaultResult = [SearchIssue.stub(id: 1, number: 1)]
        let store = try makeStore(api: seed)
        let spy = SpyNotifier()
        store.notifier = spy
        await store.refresh() // seed; marks the last successful poll as "now"

        // Simulate the laptop having been asleep well past the recency window.
        store.lastSectionPollDate = Date(timeIntervalSinceNow: -2 * NotificationDiff.recencyWindow)

        // A PR was opened during the gap — new to us, but its updatedAt is older than the window.
        var next = FakeGitHubAPI()
        next.defaultResult = [
            SearchIssue.stub(id: 1, number: 1),
            SearchIssue.stub(
                id: 42,
                number: 42,
                updatedAt: Date(timeIntervalSinceNow: -2 * NotificationDiff.recencyWindow)
            ),
        ]
        store.makeAPI = { [next] _, _ in next }
        await store.refresh()

        XCTAssertEqual(spy.posts.count, 1)
        XCTAssertTrue(spy.posts[0].body.contains("#42"))
    }

    /// A stale item suppressed by the recency gate is still folded into the baseline, so it can't
    /// resurface on a later poll — while a genuinely-new item alongside it still fires.
    func testSuppressedStaleItemIsRecordedAndDoesNotRefire() async throws {
        var seed = FakeGitHubAPI()
        seed.defaultResult = [SearchIssue.stub(id: 1, number: 1)]
        let store = try makeStore(api: seed)
        let spy = SpyNotifier()
        store.notifier = spy
        await store.refresh() // seed

        let stale = Date(timeIntervalSinceNow: -270 * 24 * 60 * 60)
        var second = FakeGitHubAPI()
        second.defaultResult = [
            SearchIssue.stub(id: 1, number: 1),
            SearchIssue.stub(id: 99, number: 99, updatedAt: stale),
        ]
        store.makeAPI = { [second] _, _ in second }
        await store.refresh() // consecutive poll → gate active → #99 suppressed but recorded

        XCTAssertTrue(spy.posts.isEmpty)

        var third = FakeGitHubAPI()
        third.defaultResult = [
            SearchIssue.stub(id: 1, number: 1),
            SearchIssue.stub(id: 99, number: 99, updatedAt: stale),
            SearchIssue.stub(id: 100, number: 100),
        ]
        store.makeAPI = { [third] _, _ in third }
        await store.refresh()

        XCTAssertEqual(spy.posts.count, 1, "#99 was recorded and must not refire; only fresh #100 banners")
        XCTAssertTrue(spy.posts[0].body.contains("#100"))
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

    /// The recovery direction: a PR whose CI was failing turns green — expect a "CI passed" banner
    /// (the success path, distinct from the failure one above).
    func testCheckStatusRecoveryNotifiesPassed() async throws {
        var seed = FakeGitHubAPI()
        seed.defaultResult = [SearchIssue.stub(id: 200, number: 12)]
        seed.pullRequestResult = .stub(number: 12, headSHA: "cafef00d")
        seed.checkRunsResult = [.stub(id: 1, name: "CI", conclusion: "failure")]
        let store = try makeStore(api: seed)
        let spy = SpyNotifier()
        store.notifier = spy

        await store.refresh() // seed: first observation (failing) stays quiet
        await store.awaitChecksHydration()
        XCTAssertTrue(spy.posts.isEmpty)

        var next = FakeGitHubAPI()
        next.defaultResult = [SearchIssue.stub(id: 200, number: 12)]
        next.pullRequestResult = .stub(number: 12, headSHA: "cafef00d")
        next.checkRunsResult = [.stub(id: 1, name: "CI", conclusion: "success")]
        store.makeAPI = { [next] _, _ in next }
        await store.refresh()
        await store.awaitChecksHydration()

        XCTAssertEqual(spy.posts.count, 1)
        XCTAssertEqual(spy.posts[0].title, "CI passed")
        XCTAssertTrue(spy.posts[0].body.contains("#12"))
    }

    /// The checks-only skip path must still fire the CI banner: a re-run flipping the result on the
    /// same commit doesn't bump `updated_at`, so the second poll skips the detail refetch — but
    /// check-runs are re-read, so the flip must still notify. Deterministic (fixed `updated_at`,
    /// blocked PR) so the skip is guaranteed to engage, unlike `testCheckStatusFlipNotifies`.
    func testCheckStatusFlipNotifiesOnChecksOnlySkip() async throws {
        let ts = Date()
        var seed = FakeGitHubAPI()
        seed.defaultResult = [SearchIssue.stub(id: 100, number: 7, updatedAt: ts)]
        seed.pullRequestResult = .stub(number: 7, headSHA: "deadbeef", mergeableState: "blocked")
        seed.checkRunsResult = [.stub(id: 1, name: "CI", conclusion: "success")]
        let store = try makeStore(api: seed)
        store.useGraphQLBatch = false // exercises the REST checks-only skip path
        let spy = SpyNotifier()
        store.notifier = spy

        await store.refresh()
        await store.awaitChecksHydration()
        XCTAssertTrue(spy.posts.isEmpty)

        // Same `updated_at` → the second poll takes the checks-only skip (no detail refetch)…
        var next = FakeGitHubAPI()
        next.defaultResult = [SearchIssue.stub(id: 100, number: 7, updatedAt: ts)]
        next.pullRequestResult = .stub(number: 7, headSHA: "deadbeef", mergeableState: "blocked")
        next.checkRunsResult = [.stub(id: 1, name: "CI", conclusion: "failure")]
        store.makeAPI = { [next] _, _ in next }
        await store.refresh()
        await store.awaitChecksHydration()

        // …but check-runs are still re-read, so the flip notifies without a detail refetch.
        XCTAssertEqual(next.recorder.pullRequestCount, 0, "checks-only skip must not refetch detail")
        XCTAssertEqual(spy.posts.count, 1)
        XCTAssertEqual(spy.posts[0].title, "CI failed")
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

    // MARK: - Authorization

    func testRefreshAuthStatusPublishesDenied() async throws {
        let store = try makeStore(api: FakeGitHubAPI())
        let spy = SpyNotifier()
        spy.stubbedAuthStatus = .denied
        store.notifier = spy

        await store.refreshNotificationAuthStatus()

        XCTAssertEqual(store.notificationAuthStatus, .denied)
    }

    func testRefreshAuthStatusWithoutNotifierIsNoOp() async throws {
        let store = try makeStore(api: FakeGitHubAPI())

        await store.refreshNotificationAuthStatus()

        XCTAssertNil(store.notificationAuthStatus)
    }

    func testRequestAuthorizationPromptsAndRefreshes() async throws {
        let store = try makeStore(api: FakeGitHubAPI())
        let spy = SpyNotifier()
        spy.stubbedAuthStatus = .notDetermined
        store.notifier = spy

        // The status published must be the post-request re-read, not the pre-prompt state.
        spy.stubbedAuthStatus = .authorized
        await store.requestNotificationAuthorization()

        XCTAssertEqual(spy.authorizationRequests, 1)
        XCTAssertEqual(store.notificationAuthStatus, .authorized)
    }

    func testSendTestNotificationPostsThroughNotifier() throws {
        let store = try makeStore(api: FakeGitHubAPI())
        let spy = SpyNotifier()
        store.notifier = spy

        store.sendTestNotification()

        XCTAssertEqual(spy.posts.count, 1)
        XCTAssertEqual(spy.posts[0].title, "gbar test notification")
        XCTAssertNil(spy.posts[0].url)
    }

    func testAuthStatusMapsProvisionalAndEphemeralToAuthorized() {
        XCTAssertEqual(NotificationAuthStatus(.notDetermined), .notDetermined)
        XCTAssertEqual(NotificationAuthStatus(.denied), .denied)
        XCTAssertEqual(NotificationAuthStatus(.authorized), .authorized)
        XCTAssertEqual(NotificationAuthStatus(.provisional), .authorized)
    }
}
