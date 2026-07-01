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

    func testApproveErrorSetsMessage() async throws {
        struct Boom: Error {}
        var fake = FakeGitHubAPI()
        fake.error = Boom()
        let store = try makeStore(api: fake)

        try await store.approve(item(SearchIssue.stub(id: 1, number: 42)))

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
        XCTAssertEqual(store.lastErrorMessage, "Session expired — reconnect in Settings.")
    }

    func testApproveUnauthorizedSetsSessionExpired() async throws {
        var fake = FakeGitHubAPI()
        fake.error = GitHubClient.ClientError.http(401)
        let store = try makeStore(api: fake)

        try await store.approve(item(SearchIssue.stub(id: 1, number: 42)))

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
        try await waitUntil { store.prChecks[self.key(100)] != nil }

        let checks = try XCTUnwrap(store.prChecks[key(100)])
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
