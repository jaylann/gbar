import Foundation
import Observation

/// Central app state: who's signed in, where the API lives, and the latest results.
/// v1 refreshes by polling `/search/issues` per account and merging; the store is the seam
/// where richer data sources (checks, notifications, a webhook backend) attach — see
/// docs/PRODUCT.md. Model types live in `AppStoreModels.swift`; loading helpers in
/// `AppStoreLoading.swift`; quick actions in `AppStoreQuickActions.swift`.
@MainActor
@Observable
final class AppStore {
    /// Every connected account. `isSignedIn` is derived from this (plus a not-yet-migrated
    /// legacy token). Metadata is persisted to UserDefaults; tokens live in the Keychain.
    private(set) var accounts: [Account] = []
    /// Full merged results across all accounts. The account filter is applied in the
    /// view-facing computed properties, not here, so switching accounts is instant.
    private(set) var sections: [LoadedSection] = []
    /// The signed-in users' notification inboxes (`GET /notifications`), tagged by account.
    /// Loaded best-effort alongside sections so a notifications failure never blanks the lists.
    private(set) var notifications: [AccountNotification] = []
    /// Best-effort CI status per PR, keyed by `(accountID, prID)`. Kept in a side map (not on
    /// `LoadedSection`) because it's hydrated asynchronously after the initial load and is
    /// decorative — a failure here never blocks the list or surfaces an error.
    private(set) var prChecks: [PRCheckKey: PRChecks] = [:]
    var isRefreshing = false
    var lastErrorMessage: String?
    var sessionExpired = false
    /// True once at least one refresh has completed — lets the UI tell "first load"
    /// (show a skeleton) apart from "loaded and genuinely empty" (show caught-up).
    private(set) var hasLoaded = false

    /// A legacy single-token credential (`"github.token"`) awaiting migration into an
    /// `Account`. Resolved lazily on the next refresh (needs `currentUser()` to learn the
    /// login). Keeps `isSignedIn` true across the async migration so the UI doesn't flash the
    /// sign-in prompt.
    var pendingLegacyToken: String?

    /// GitHub API base — the default host for new github.com accounts and the base used to
    /// migrate a legacy token. Per-account hosts live on `Account.apiBaseURL`.
    var apiBaseURL: URL {
        didSet { UserDefaults.standard.set(apiBaseURL.absoluteString, forKey: Self.apiBaseURLKey) }
    }

    static let apiBaseURLKey = "gbar.apiBaseURL"

    /// The active account filter (`nil` = All). Persisted so the chosen scope survives relaunch.
    var accountFilter: Account.ID? {
        didSet {
            if let accountFilter {
                UserDefaults.standard.set(accountFilter, forKey: Self.accountFilterKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.accountFilterKey)
            }
        }
    }

    static let accountFilterKey = "gbar.accountFilter"
    static let accountsKey = "gbar.accounts"

    /// Background auto-refresh cadence in seconds; 0 disables polling. Changing it restarts
    /// the poll loop at the new interval. Persisted like `apiBaseURL`.
    var pollInterval: TimeInterval {
        didSet {
            UserDefaults.standard.set(pollInterval, forKey: Self.pollIntervalKey)
            startPolling()
        }
    }

    static let pollIntervalKey = "gbar.pollInterval"

    /// The single in-flight poll loop, if any. `@MainActor`-isolated like the rest of the store.
    var pollTask: Task<Void, Never>?

    /// Bumped on every hydration wave (and on account add/remove/sign-out) so a slow, in-flight
    /// CI hydration from a previous refresh can detect it's stale and drop its writes instead of
    /// clobbering fresher results — or repopulating `prChecks` after sign-out.
    var checksGeneration = 0

    /// The single in-flight CI hydration wave, if any. Cancelled when a new wave starts and on
    /// sign-out so stale check-runs requests stop firing with a removed token.
    var checksTask: Task<Void, Never>?

    /// Max concurrent PR-detail+check-runs fetches during CI hydration — this is an N+1 over
    /// the PR list (two requests each), so cap it to stay friendly to GitHub's rate limit.
    static let checksConcurrency = 5

    /// Builds the API client used by `refresh()`. Overridable so tests can inject a fake
    /// `GitHubAPI` without touching the network; defaults to the live `GitHubClient`.
    @ObservationIgnored
    var makeAPI: @Sendable (_ baseURL: URL, _ token: String) -> GitHubAPI = { GitHubClient(baseURL: $0, token: $1) }

    /// Reads an account's token. Injectable so tests avoid the Keychain; defaults to the
    /// per-account Keychain key.
    @ObservationIgnored
    var tokenForAccount: @Sendable (_ account: Account) -> String? = { KeychainStore.get($0.keychainKey) }

    /// Persists a token under a Keychain key. Injectable for tests.
    @ObservationIgnored
    var storeToken: @Sendable (_ token: String, _ key: String) throws -> Void = { try KeychainStore.set($0, for: $1) }

    /// Removes a token by Keychain key. Injectable for tests.
    @ObservationIgnored
    var deleteToken: @Sendable (_ key: String) -> Void = { KeychainStore.remove($0) }

    /// User-editable menu sections. Seeded from `SearchQuery.defaults` on first launch;
    /// persisted as JSON so custom queries and ordering survive relaunches.
    var savedQueries: [SearchQuery.Section] {
        didSet {
            if let data = try? JSONEncoder().encode(savedQueries) {
                UserDefaults.standard.set(data, forKey: Self.savedQueriesKey)
            }
        }
    }

    static let savedQueriesKey = "gbar.savedQueries"

    var isSignedIn: Bool {
        !accounts.isEmpty || pendingLegacyToken != nil
    }

    // MARK: View-facing (account-filtered) projections

    /// Apply the active account filter to a set of tagged items. `nil` filter = pass-through.
    func visible(_ items: [AccountItem]) -> [AccountItem] {
        guard let filter = accountFilter else { return items }
        return items.filter { $0.account.id == filter }
    }

    /// Notifications scoped to the active account filter.
    var visibleNotifications: [AccountNotification] {
        guard let filter = accountFilter else { return notifications }
        return notifications.filter { $0.account.id == filter }
    }

    /// Count of actionable PRs — review-requested plus assigned — shown on the menu-bar icon.
    /// Intentionally global (ignores the in-menu account filter): the icon reflects app-wide
    /// state, not a transient view scope.
    var badgeCount: Int {
        let actionable: Set = ["review-requested", "assigned-prs"]
        return sections.filter { actionable.contains($0.id) }.reduce(0) { $0 + $1.items.count }
    }

    /// Loaded sections routed to the PRs tab, account-filtered.
    var prSections: [LoadedSection] {
        filteredSections(kind: .prs)
    }

    /// Loaded sections routed to the Issues tab, account-filtered.
    var issueSections: [LoadedSection] {
        filteredSections(kind: .issues)
    }

    private func filteredSections(kind: SearchQuery.Section.Kind) -> [LoadedSection] {
        sections
            .filter { $0.kind == kind }
            .map { LoadedSection(id: $0.id, title: $0.title, items: visible($0.items), kind: $0.kind) }
    }

    /// Total PR-section items (filtered) — the count shown on the PRs tab.
    var prCount: Int {
        prSections.reduce(0) { $0 + $1.items.count }
    }

    /// Total issue-section items (filtered) — the count shown on the Issues tab.
    var issueCount: Int {
        issueSections.reduce(0) { $0 + $1.items.count }
    }

    /// Unread notifications (filtered) — the count shown on the Notifications tab.
    var unreadNotificationCount: Int {
        visibleNotifications.filter(\.notification.unread).count
    }

    /// The hydrated CI status/detail for a tagged PR item, if any.
    func checks(for item: AccountItem) -> PRChecks? {
        prChecks[PRCheckKey(accountID: item.account.id, prID: item.issue.id)]
    }

    init() {
        if let stored = UserDefaults.standard.string(forKey: Self.apiBaseURLKey), let url = URL(string: stored) {
            apiBaseURL = url
        } else {
            apiBaseURL = AppConfig.defaultAPIBaseURL
        }
        // Validate the restored value against the known intervals so a corrupt/legacy default
        // (e.g. a tiny 0.001 that would spin the loop hot) can't reach the poll loop.
        if UserDefaults.standard.object(forKey: Self.pollIntervalKey) != nil,
           let stored = PollInterval(rawValue: UserDefaults.standard.double(forKey: Self.pollIntervalKey))
        {
            pollInterval = stored.rawValue
        } else {
            pollInterval = PollInterval.m1.rawValue
        }
        // Key absent → first launch, seed defaults. Key present (even if `[]`) → the user
        // may have intentionally cleared the list, so respect it and don't resurrect defaults.
        if let data = UserDefaults.standard.data(forKey: Self.savedQueriesKey) {
            do {
                savedQueries = try JSONDecoder().decode([SearchQuery.Section].self, from: data)
            } catch {
                Log.store.error("saved queries decode failed: \(error.localizedDescription, privacy: .public)")
                savedQueries = SearchQuery.defaults
            }
        } else {
            savedQueries = SearchQuery.defaults
        }
        restorePersistedAccounts()
        startPolling()
    }

    /// Restore connected accounts (metadata only; tokens stay in the Keychain), the account
    /// filter (dropped if it no longer names a live account), and stage any legacy single-token
    /// credential for migration on the next refresh.
    private func restorePersistedAccounts() {
        if let data = UserDefaults.standard.data(forKey: Self.accountsKey),
           let decoded = try? JSONDecoder().decode([Account].self, from: data)
        {
            accounts = decoded
        }
        if let filter = UserDefaults.standard.string(forKey: Self.accountFilterKey),
           accounts.contains(where: { $0.id == filter })
        {
            accountFilter = filter
        }
        // Legacy single-token upgrade: defer resolution (needs `currentUser()`) to the first
        // refresh, but keep the token so `isSignedIn` is already true.
        if accounts.isEmpty, let token = KeychainStore.get(Credential.keychainKey) {
            pendingLegacyToken = token
        }
    }

    #if DEBUG
    /// Test-only initializer: fixed base URL, already-connected accounts, an injectable API
    /// factory, and a constant token per account — no Keychain/UserDefaults reads.
    init(
        apiBaseURL: URL,
        accounts: [Account],
        makeAPI: @escaping @Sendable (URL, String) -> GitHubAPI,
        token: String = "test-token"
    ) {
        self.apiBaseURL = apiBaseURL
        pollInterval = PollInterval.off.rawValue
        savedQueries = SearchQuery.defaults
        self.accounts = accounts
        self.makeAPI = makeAPI
        tokenForAccount = { _ in token }
    }

    /// Test hook: await the current CI hydration wave (if any) to completion.
    func awaitChecksHydration() async {
        await checksTask?.value
    }

    /// Test hook: hand back the in-flight hydration task so a test can hold a reference across
    /// a sign-out (which nils the store's own reference) and still await the wave.
    var checksHydrationTaskForTests: Task<Void, Never>? {
        checksTask
    }

    /// Test hook: seed/inspect the pending legacy token so migration can be driven in a test.
    var pendingLegacyTokenForTests: String? {
        get { pendingLegacyToken }
        set { pendingLegacyToken = newValue }
    }
    #endif
}

// MARK: - Saved queries

extension AppStore {
    /// Append a fresh, empty saved query for the user to fill in. The UUID id keeps it
    /// distinct from the baseline sections (so badge/actionable semantics are unaffected).
    func addSavedQuery() {
        savedQueries.append(SearchQuery.Section(id: UUID().uuidString, title: "", query: "", kind: nil))
    }

    func deleteSavedQuery(at offsets: IndexSet) {
        savedQueries.remove(atOffsets: offsets)
    }

    func moveSavedQuery(from source: IndexSet, to destination: Int) {
        savedQueries.move(fromOffsets: source, toOffset: destination)
    }
}

// MARK: - Refresh

extension AppStore {
    /// Refresh every section for every account and merge the results. Accounts are fetched
    /// concurrently in a `TaskGroup`; the merged data is kept whole and the account filter is
    /// applied only in the view-facing projections, so switching accounts needs no refetch.
    func refresh() async {
        await migrateLegacyCredentialIfNeeded()
        guard !accounts.isEmpty else { return }
        isRefreshing = true
        lastErrorMessage = nil
        sessionExpired = false
        defer {
            isRefreshing = false
            hasLoaded = true
        }

        // One API client per account (skipping any whose token has gone missing), reused for
        // both the section load and CI hydration.
        let accountAPIs = currentAccountAPIs()
        guard !accountAPIs.isEmpty else { return }

        let queries = savedQueries
        var loadsByAccount: [Account.ID: AccountLoad] = [:]
        await withTaskGroup(of: AccountLoad.self) { group in
            for pair in accountAPIs {
                group.addTask { await Self.load(account: pair.account, api: pair.api, queries: queries) }
            }
            for await load in group {
                loadsByAccount[load.account.id] = load
            }
        }

        sections = mergeSections(loadsByAccount, queries: queries)
        notifications = mergeNotifications(loadsByAccount)
        applyErrorState(from: loadsByAccount)

        let apis = Dictionary(uniqueKeysWithValues: accountAPIs.map { ($0.account.id, $0.api) })
        // Kick off CI hydration without awaiting it, so the list shows immediately.
        hydrateChecks(for: sections, apis: apis)
    }

    private func currentAccountAPIs() -> [(account: Account, api: GitHubAPI)] {
        accounts.compactMap { account in
            guard let token = tokenForAccount(account) else { return nil }
            return (account, makeAPI(account.apiBaseURL, token))
        }
    }

    /// Merge each query's per-account results into one section, preserving section order
    /// (savedQueries) and account order (accounts). A section is included only if at least one
    /// account returned it, mirroring the single-account behaviour of skipping a failed query.
    private func mergeSections(
        _ loads: [Account.ID: AccountLoad],
        queries: [SearchQuery.Section]
    )
    -> [LoadedSection] {
        var merged: [LoadedSection] = []
        for query in queries where query.isRunnable {
            let anyReturned = accounts.contains { loads[$0.id]?.sections[query.id] != nil }
            guard anyReturned else { continue }
            var items: [AccountItem] = []
            for account in accounts {
                let issues = loads[account.id]?.sections[query.id] ?? []
                items.append(contentsOf: issues.map { AccountItem(account: account, issue: $0) })
            }
            merged.append(LoadedSection(id: query.id, title: query.title, items: items, kind: query.resolvedKind))
        }
        return merged
    }

    private func mergeNotifications(_ loads: [Account.ID: AccountLoad]) -> [AccountNotification] {
        accounts.flatMap { account in
            (loads[account.id]?.notifications ?? [])
                .map { AccountNotification(account: account, notification: $0) }
        }
    }

    /// Any 401 surfaces the reconnect prompt; otherwise the first non-auth error message wins.
    private func applyErrorState(from loads: [Account.ID: AccountLoad]) {
        let expired = loads.values.contains(where: \.sessionExpired)
        sessionExpired = expired
        if expired {
            lastErrorMessage = "Session expired — reconnect in Settings."
        } else {
            lastErrorMessage = loads.values.compactMap(\.errorMessage).first
        }
    }

    /// Mark a notification thread read on the server (using its own account's token), then
    /// drop it from the local inbox once the call succeeds (pessimistic). On failure the item
    /// stays put and the error surfaces via `lastErrorMessage`.
    func markRead(_ item: AccountNotification) async {
        guard let token = tokenForAccount(item.account) else { return }
        let api = makeAPI(item.account.apiBaseURL, token)
        do {
            try await api.markNotificationRead(threadID: item.notification.id)
            notifications.removeAll { $0.id == item.id }
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = "Couldn't mark notification as read."
            Log.network.error("mark notification read failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Drop an item (by composite id) from every loaded section — optimistic UI after a merge.
    func removeItem(id: AccountItem.ID) {
        sections = sections.map { section in
            LoadedSection(
                id: section.id,
                title: section.title,
                items: section.items.filter { $0.id != id },
                kind: section.kind
            )
        }
    }
}

// MARK: - Account management

extension AppStore {
    /// Validate a token against `currentUser()`, then connect it as an account. Throws on an
    /// invalid token (so the caller can show an inline error) and leaves state untouched.
    func addAccount(token: String, kind: Credential.Kind, apiBaseURL: URL) async throws {
        let api = makeAPI(apiBaseURL, token)
        let user = try await api.currentUser()
        let account = Account(login: user.login, avatarURL: user.avatarURL, kind: kind, apiBaseURL: apiBaseURL)
        try storeToken(token, account.keychainKey)
        // Re-adding an existing login (e.g. reconnect) replaces the stale metadata in place.
        accounts.removeAll { $0.id == account.id }
        accounts.append(account)
        persistAccounts()
        checksTask?.cancel()
        checksGeneration += 1
        lastErrorMessage = nil
        sessionExpired = false
        startPolling()
        await refresh()
    }

    /// Remove one account: drop its token, metadata, and all of its merged data. If it was the
    /// filtered account, reset the filter. Removing the last account clears everything.
    func removeAccount(id: Account.ID) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        let account = accounts.remove(at: index)
        deleteToken(account.keychainKey)
        persistAccounts()
        if accountFilter == id { accountFilter = nil }
        checksTask?.cancel()
        checksGeneration += 1
        sections = sections.map { section in
            LoadedSection(
                id: section.id,
                title: section.title,
                items: section.items.filter { $0.account.id != id },
                kind: section.kind
            )
        }
        notifications.removeAll { $0.account.id == id }
        prChecks = prChecks.filter { $0.key.accountID != id }
        if accounts.isEmpty {
            resetSignedOutState()
        } else {
            startPolling()
        }
    }

    /// Sign out of every account at once.
    func signOutAll() {
        for account in accounts {
            deleteToken(account.keychainKey)
        }
        // Clean up any un-migrated legacy token too.
        deleteToken(Credential.keychainKey)
        pendingLegacyToken = nil
        accounts = []
        persistAccounts()
        accountFilter = nil
        checksTask?.cancel()
        checksGeneration += 1
        resetSignedOutState()
    }

    /// Clear all loaded data and stop polling — shared by "remove last account" and "sign out".
    private func resetSignedOutState() {
        stopPolling()
        checksTask?.cancel()
        checksTask = nil
        checksGeneration += 1
        sections = []
        notifications = []
        prChecks = [:]
        hasLoaded = false
        sessionExpired = false
        lastErrorMessage = nil
        // Drop any un-migrated legacy token too, so removing the last account can't leave
        // `isSignedIn` stuck true (with zero accounts) on a revoked/never-migrated credential.
        pendingLegacyToken = nil
    }

    private func persistAccounts() {
        if let data = try? JSONEncoder().encode(accounts) {
            UserDefaults.standard.set(data, forKey: Self.accountsKey)
        }
    }

    /// Resolve a legacy single-token credential into an `Account`. Idempotent (no-op once the
    /// pending token is cleared) and non-destructive: on failure the legacy token is left in
    /// place so a later refresh can retry. Device flow has no refresh token, so we don't know
    /// the original `kind` — default to `.oauth` (the common case).
    func migrateLegacyCredentialIfNeeded() async {
        guard let token = pendingLegacyToken else { return }
        let api = makeAPI(apiBaseURL, token)
        do {
            let user = try await api.currentUser()
            let account = Account(login: user.login, avatarURL: user.avatarURL, kind: .oauth, apiBaseURL: apiBaseURL)
            try storeToken(token, account.keychainKey)
            accounts.removeAll { $0.id == account.id }
            accounts.append(account)
            persistAccounts()
            deleteToken(Credential.keychainKey)
            pendingLegacyToken = nil
            Log.auth.info("migrated legacy token to account \(account.login, privacy: .public)")
        } catch {
            Log.auth.error("legacy token migration failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Start (or restart) the background poll loop. Cancels any existing loop first; a no-op
    /// when signed out or when polling is `.off`.
    func startPolling() {
        pollTask?.cancel()
        guard isSignedIn, pollInterval > 0 else {
            pollTask = nil
            return
        }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.isSignedIn, self.pollInterval > 0 else { return }
                if !self.isRefreshing { await self.refresh() }
                let seconds = self.pollInterval
                do {
                    try await Task.sleep(for: .seconds(seconds))
                } catch {
                    return // cancelled
                }
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }
}

// MARK: - CI hydration

extension AppStore {
    /// Best-effort CI hydration across accounts: for every distinct PR (keyed per account),
    /// fetch its detail then its check runs using that account's client, roll them up, and
    /// stash the result in `prChecks`. Runs in a detached, non-blocking task with a capped
    /// `TaskGroup`; failures are swallowed. Stale runs are dropped via `checksGeneration`.
    func hydrateChecks(for sections: [LoadedSection], apis: [Account.ID: GitHubAPI]) {
        // Supersede any previous wave so it stops firing requests and can't clobber this one.
        checksTask?.cancel()
        checksGeneration += 1
        let prs = distinctPRFetches(from: sections, apis: apis)
        // Prune entries for PRs no longer in the list so a dropped-out PR's stale CI dot can't
        // linger (and `prChecks` can't grow unbounded).
        let live = Set(prs.map(\.key))
        prChecks = prChecks.filter { live.contains($0.key) }
        guard !prs.isEmpty else {
            checksTask = nil
            return
        }
        checksTask = checksWave(prs: prs, generation: checksGeneration)
    }

    private typealias CheckFetch = (key: PRCheckKey, issue: SearchIssue, api: GitHubAPI)

    /// Distinct `(account, PR)` fetches — the same PR can appear in several sections, and each
    /// account has its own client.
    private func distinctPRFetches(from sections: [LoadedSection], apis: [Account.ID: GitHubAPI]) -> [CheckFetch] {
        var seen = Set<PRCheckKey>()
        return sections
            .flatMap(\.items)
            .filter(\.issue.isPullRequest)
            .compactMap { item in
                let key = PRCheckKey(accountID: item.account.id, prID: item.issue.id)
                guard seen.insert(key).inserted, let api = apis[item.account.id] else { return nil }
                return (key, item.issue, api)
            }
    }

    /// The capped-concurrency hydration wave. Stale runs (a superseded `generation`) drop their
    /// writes.
    private func checksWave(prs: [CheckFetch], generation: Int) -> Task<Void, Never> {
        Task { [weak self] in
            await withTaskGroup(of: (PRCheckKey, PRChecks?).self) { group in
                var next = 0
                func schedule() {
                    guard next < prs.count else { return }
                    let pr = prs[next]
                    next += 1
                    group.addTask { await (pr.key, Self.fetchChecks(for: pr.issue, using: pr.api)) }
                }
                for _ in 0..<Self.checksConcurrency {
                    schedule()
                }
                while let (key, checks) = await group.next() {
                    guard let self, self.checksGeneration == generation else { continue }
                    // Write the fresh result, or clear a now-empty/failed entry so a stale dot
                    // (e.g. green after CI started failing) doesn't survive.
                    self.prChecks[key] = checks
                    schedule()
                }
            }
        }
    }
}
