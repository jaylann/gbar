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
    /// Full merged results across all accounts. The account filter is applied into the cached
    /// projections below (not on every view read), so switching accounts is instant.
    private(set) var sections: [LoadedSection] = [] {
        didSet { recomputeSectionProjections() }
    }

    /// The signed-in users' notification inboxes (`GET /notifications`), tagged by account.
    /// Loaded best-effort alongside sections so a notifications failure never blanks the lists.
    private(set) var notifications: [AccountNotification] = [] {
        didSet { recomputeNotificationProjection() }
    }

    /// Cached account-filtered projections the menu renders from — the PRs/Issues tab sections and
    /// the visible notification inbox. Recomputed by the `recompute*` helpers in `AppStoreProjections`
    /// only when `sections`, `notifications`, or `accountFilter` change, so a view body pass (e.g.
    /// every search keystroke or incremental CI hydration write) reads them instead of re-filtering
    /// the whole result set each frame. Written only by those helpers; views read only.
    var prSections: [LoadedSection] = []
    var issueSections: [LoadedSection] = []
    var visibleNotifications: [AccountNotification] = []

    /// Best-effort CI status per PR, keyed by `(accountID, prID)`. Kept in a side map (not on
    /// `LoadedSection`) because it's hydrated asynchronously after the initial load and is
    /// decorative — a failure here never blocks the list or surfaces an error. Written only by
    /// the hydration wave (`AppStoreHydration.swift`) and the reset sites here; views read only.
    var prChecks: [PRCheckKey: PRChecks] = [:]
    /// Best-effort action gate per PR, keyed like `prChecks`. Decides whether the hover
    /// Approve/Merge buttons show; hydrated in the same wave as `prChecks`. Absent = not yet
    /// hydrated → the row stays optimistic (buttons show). Written only by the hydration wave
    /// and the reset sites here; views read only.
    var prGates: [PRCheckKey: PRGate] = [:]
    /// Monotonic clock for `prGates` writes. Both writers — the hydration wave's fresh full-fetch
    /// (`publishChecks`) and the merge-readiness poll's single-key write (`refreshPRState`) — take
    /// a tick when they *issue* their detail fetch, so a batch republish can resolve each key by
    /// which fetch read the newer server state instead of clobbering a fresher gate with a staler
    /// one (#84). Issue-time, not commit-time: the wave's full fetch folds only after its slow
    /// checks/reviews legs, so a fetch that observed an older gate can commit *after* a fresher
    /// poll write — issue order is the honest recency signal. Bookkeeping, never read from a view.
    @ObservationIgnored
    var gateWriteClock = 0
    /// The `gateWriteClock` issue tick of the fetch whose result currently sits in `prGates[key]`
    /// (see `gateWriteClock`). Pruned alongside `prGates`.
    @ObservationIgnored
    var prGateSeq: [PRCheckKey: Int] = [:]
    /// What each PR looked like at its last successful hydration — the `updated_at` we hydrated
    /// against and whether its CI had settled. Lets the next wave skip the detail/reviews/check-runs
    /// refetch for a PR that hasn't changed (see `canSkipHydration`). Never read from a view, so
    /// it's `@ObservationIgnored` — it's a request-saving cache, not display state.
    @ObservationIgnored
    var prHydrationMark: [PRCheckKey: HydrationMark] = [:]
    /// Cache of the viewer's merge signals per repo (push access + allowed strategies), keyed
    /// `"\(accountID)\n\(slug)"`. Filled lazily during hydration so we don't refetch
    /// `GET /repos/{repo}` every poll; a repo's permissions/settings rarely change within a
    /// session (and are refreshed on relaunch). Mutated by the hydration helpers in
    /// `AppStoreHydration.swift`, so it's internal (not `private`).
    var repoMergeInfo: [String: RepoMergeInfo] = [:]
    /// The `owner/name` slugs each account has starred (lowercased for case-insensitive
    /// membership), keyed by account. A cross-tab signal: rows on a starred repo get a marker,
    /// and the "Starred" filter narrows every tab to them. Loaded best-effort alongside sections.
    var starredByAccount: [Account.ID: Set<String>] = [:]
    /// Recent Actions workflow runs across the watched repos (see `watchlist`), merged and sorted
    /// newest-first. Written only by the repo-feeds hydration wave (`AppStoreRepoFeeds.swift`) and
    /// the reset sites here, so it's internal (not `private(set)`); views read only.
    var actionRuns: [AccountActionRun] = []
    /// Recent releases across the watched repos, merged and sorted newest-first. Written only by
    /// the same wave as `actionRuns`; views read only.
    var releases: [AccountRelease] = []
    /// Bumped on every repo-feeds wave (and on account add/remove/sign-out) so a slow in-flight
    /// wave can detect it's stale and drop its writes — mirrors `checksGeneration`.
    var repoFeedsGeneration = 0
    /// The single in-flight repo-feeds (Actions + Releases) hydration wave, if any.
    var repoFeedsTask: Task<Void, Never>?
    /// True once the first repo-feeds wave has completed — lets the Actions/Releases tabs tell
    /// "still loading" (skeleton) apart from "loaded and empty" (caught-up / add-repos nudge).
    /// Written by the wave and the reset sites, so it's internal.
    var hasLoadedRepoFeeds = false
    var isRefreshing = false
    var lastErrorMessage: String?
    /// When GitHub last rate-limited a load (from `Retry-After` / `X-RateLimit-Reset`), the time
    /// access is expected back. The poll loop backs off until then instead of re-polling into
    /// GitHub's secondary rate limit; `nil` when not rate-limited. Recomputed every refresh.
    var rateLimitedUntil: Date?
    var sessionExpired = false
    /// The account whose token last returned a 401, if any — drives the per-account "Reconnect
    /// <login>" prompt (see `AppStore+Reauth`). `nil` when no session is expired. If several
    /// accounts expire at once, this tracks the first in account order — a documented v1
    /// simplification; the user can repeat the reconnect for the next one.
    private(set) var expiredAccountID: Account.ID?
    /// Progress of an in-place device-flow reconnect triggered from the 401 prompt. `.idle`
    /// except while a reconnect is running (or just failed). Driven by `reconnect(openURL:)` in
    /// `AppStore+Reauth` (internal setter so that extension can update it).
    var reauthStatus: ReauthStatus = .idle
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
        didSet { defaults.set(apiBaseURL.absoluteString, forKey: Self.apiBaseURLKey) }
    }

    static let apiBaseURLKey = "gbar.apiBaseURL"

    /// The OAuth App client ID last used for a device-flow sign-in. A **public** identifier (not
    /// a secret — those live in the Keychain), so it's persisted in UserDefaults, letting the 401
    /// "Reconnect" re-run the device flow in place without the user re-entering it. Defaults to
    /// the build's baked client ID (blank on self-host builds until the user supplies one).
    var oauthClientID: String {
        didSet { defaults.set(oauthClientID, forKey: Self.oauthClientIDKey) }
    }

    static let oauthClientIDKey = "gbar.oauthClientID"

    /// The active account filter (`nil` = All). Persisted so the chosen scope survives relaunch.
    var accountFilter: Account.ID? {
        didSet {
            if let accountFilter {
                defaults.set(accountFilter, forKey: Self.accountFilterKey)
            } else {
                defaults.removeObject(forKey: Self.accountFilterKey)
            }
            // The filter feeds both projections, so re-derive both when it changes.
            recomputeSectionProjections()
            recomputeNotificationProjection()
        }
    }

    static let accountFilterKey = "gbar.accountFilter"
    static let accountsKey = "gbar.accounts"

    /// Background auto-refresh cadence in seconds; 0 disables polling. Changing it restarts
    /// the poll loop at the new interval. Persisted like `apiBaseURL`.
    var pollInterval: TimeInterval {
        didSet {
            defaults.set(pollInterval, forKey: Self.pollIntervalKey)
            startPolling()
        }
    }

    static let pollIntervalKey = "gbar.pollInterval"

    /// The single in-flight poll loop, if any. `@MainActor`-isolated like the rest of the store.
    var pollTask: Task<Void, Never>?

    /// The single in-flight refresh, if any. Makes `refresh()` single-flight: concurrent callers
    /// (poll loop, menu open, manual button, reconnect, account-add) coalesce onto this one run
    /// instead of starting overlapping refreshes whose @MainActor-interleaved awaits would clobber
    /// each other's partial state (`sections`, notification baselines, CI generation). See #10.
    var refreshTask: Task<Void, Never>?

    /// Bumped on every hydration wave (and on account add/remove/sign-out) so a slow, in-flight
    /// CI hydration from a previous refresh can detect it's stale and drop its writes instead of
    /// clobbering fresher results — or repopulating `prChecks` after sign-out.
    var checksGeneration = 0

    /// The single in-flight CI hydration wave, if any. Cancelled when a new wave starts and on
    /// sign-out so stale check-runs requests stop firing with a removed token.
    var checksTask: Task<Void, Never>?

    /// The background poll started after an approval to reveal Merge once GitHub finishes
    /// recomputing the PR's `mergeable_state` (which lags the approval by seconds). Kept off the
    /// approve call's own async path so the inline composer closes immediately instead of spinning
    /// for the whole poll. Cancelled on sign-out and superseded by the next approval.
    var mergeReadinessTask: Task<Void, Never>?

    /// Max concurrent PR-detail+check-runs fetches during CI hydration — this is an N+1 over
    /// the PR list (two requests each), so cap it to stay friendly to GitHub's rate limit.
    static let checksConcurrency = 5

    /// How many hydration completions to accumulate before publishing them to `prChecks`/`prGates`
    /// in one batched assignment. Each publish invalidates every view reading those maps, so
    /// batching keeps the post-open wave to a handful of render passes instead of one per PR while
    /// still revealing CI state progressively.
    static let checksFlushBatch = 8

    /// Whether the CI/gate hydration wave uses the batched GraphQL query (`pullRequestBatch`,
    /// one round-trip per account) instead of the per-PR REST triple. On by default; any GraphQL
    /// failure (a GHE server missing a field, a transport error) auto-falls-back to the REST path
    /// per account. Tests flip it to `false` to exercise the REST short-circuit path directly.
    @ObservationIgnored
    var useGraphQLBatch = true

    /// Persistence backend for all non-secret state (the `didSet` writes above/below).
    /// `.standard` in the app; the test init substitutes an isolated, wiped suite so store
    /// mutations in tests can never leak into the real `dev.lanfermann.gbar` domain.
    let defaults: UserDefaults

    /// Builds the API client used by `refresh()`. Overridable so tests can inject a fake
    /// `GitHubAPI` without touching the network; defaults to the live `GitHubClient`.
    @ObservationIgnored
    var makeAPI: @Sendable (_ baseURL: URL, _ token: String) -> GitHubAPI = { GitHubClient(baseURL: $0, token: $1) }

    /// Builds the device-flow actor used by add-account and reconnect. Overridable so tests
    /// can hand back a client wired to a mocked `URLSession`; defaults to the live client.
    @ObservationIgnored
    var makeDeviceFlowClient: @Sendable (_ clientID: String, _ webBaseURL: URL) -> DeviceFlowClient =
        { DeviceFlowClient(clientID: $0, webBaseURL: $1) }

    /// Suspends for a duration between poll attempts. Overridable so tests can run the
    /// post-approve poll to completion instantly; defaults to a real `Task.sleep`. Never read from
    /// a view body, so it needs no `@ObservationIgnored`.
    var sleep: @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }

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

    // MARK: Desktop notifications

    /// Posts native desktop banners. Injected by the app (`StatusItemController`) so the store
    /// stays testable — tests substitute a spy. Nil in tests that don't exercise notifications.
    @ObservationIgnored
    var notifier: (any DesktopNotifying)?

    /// Last observed OS-level notification authorization; nil until first queried. Not
    /// persisted — always re-read live so it tracks System Settings.
    var notificationAuthStatus: NotificationAuthStatus?

    // MARK: Launch at login

    /// Registers/unregisters gbar as a macOS login item. Injected by the app
    /// (`StatusItemController`) so the store stays testable — a real `SMAppService` call in a
    /// unit-test bundle would target the test runner. Nil in tests that don't exercise it.
    @ObservationIgnored
    var launchAtLogin: (any LaunchAtLoginManaging)?

    /// Observable mirror of the login-item state the Settings toggle binds to. Not persisted —
    /// the OS owns the truth (`SMAppService.mainApp.status`), so it's re-read live via
    /// `refreshLaunchAtLoginStatus()`, tracking changes made in System Settings. Inline default
    /// lets the test-only init skip it.
    var launchAtLoginEnabled = false

    /// Master switch for desktop notifications, plus per-category toggles. All default on;
    /// persisted like `apiBaseURL`. Inline defaults let the test-only init skip them.
    var notificationsEnabled = true {
        didSet { defaults.set(notificationsEnabled, forKey: Self.notificationsEnabledKey) }
    }

    var notifyInbox = true {
        didSet { defaults.set(notifyInbox, forKey: Self.notifyInboxKey) }
    }

    var notifySections = true {
        didSet { defaults.set(notifySections, forKey: Self.notifySectionsKey) }
    }

    var notifyChecks = true {
        didSet { defaults.set(notifyChecks, forKey: Self.notifyChecksKey) }
    }

    static let notificationsEnabledKey = "gbar.notificationsEnabled"
    static let notifyInboxKey = "gbar.notifyInbox"
    static let notifySectionsKey = "gbar.notifySections"
    static let notifyChecksKey = "gbar.notifyChecks"

    /// Which sources feed the menu-bar badge count (`BadgeSource` raw values). Defaults to
    /// review-requested only — the sharpest "someone is waiting on you" signal. The badge is
    /// derived from this in `badgeCount`/`badgeBreakdown` (see `AppStoreProjections`), so the
    /// status item re-renders the instant it changes. Persisted as a plain string array; the
    /// inline default lets the test-only init skip it.
    var badgeSources: Set<String> = [BadgeSource.reviewRequested.rawValue] {
        didSet { defaults.set(Array(badgeSources), forKey: Self.badgeSourcesKey) }
    }

    static let badgeSourcesKey = "gbar.badgeSources"

    /// Notification baselines, keyed by a composite of the owning account so ids never collide
    /// across hosts. See `AppStoreNotifications.swift` for the diff + seeding logic.
    ///
    /// - `seenSectionItemKeys`: `"<account.id>\n<query.id>\n<issue.id>"` for every successfully
    ///   loaded section item. Query-scoped so a single failed section can be preserved
    ///   independently of its siblings.
    /// - `seededSectionKeys`: `"<account.id>\n<query.id>"` pairs whose first (silent) load has
    ///   happened, so their next new item notifies rather than re-seeding.
    /// - `lastUnreadInboxKeys`: `"<account.id>\n<notification.id>"` for the previous poll's unread
    ///   threads; `seededInboxAccounts`: account ids whose inbox has been seeded.
    /// - `lastCheckStatus`: last observed terminal CI status per `(account, PR)`.
    /// - `lastSectionPollDate`: when the last *successful* section poll ran. Gates the section
    ///   recency filter — after a gap longer than the recency window (sleep/outage/polling off)
    ///   the filter is skipped so a genuinely-new item isn't dropped just for predating the gap.
    var seenSectionItemKeys: Set<String> = []
    var seededSectionKeys: Set<String> = []
    var lastUnreadInboxKeys: Set<String> = []
    var seededInboxAccounts: Set<Account.ID> = []
    var lastCheckStatus: [PRCheckKey: CIStatus] = [:]
    var lastSectionPollDate: Date?

    /// User-editable menu sections. Seeded from `SearchQuery.defaults` on first launch;
    /// persisted as JSON so custom queries and ordering survive relaunches.
    var savedQueries: [SearchQuery.Section] {
        didSet { persistJSON(savedQueries, forKey: Self.savedQueriesKey) }
    }

    static let savedQueriesKey = "gbar.savedQueries"

    /// The repos (as `owner/name` slugs) to iterate for the per-repo surfaces — Actions runs and
    /// Releases. Explicit and user-curated (Settings ▸ Watchlist): this is the *authoritative*
    /// scope for those tabs, deliberately not the starred set, so the per-repo request fan-out
    /// stays bounded and predictable. Persisted as JSON like `savedQueries`.
    var watchlist: [String] {
        didSet { persistJSON(watchlist, forKey: Self.watchlistKey) }
    }

    static let watchlistKey = "gbar.watchlist"

    /// Shared persistence path for the JSON-backed preferences (`savedQueries`, `watchlist`):
    /// encode to `defaults`, logging rather than throwing on the (unexpected) encode failure.
    private func persistJSON(_ value: some Encodable, forKey key: String) {
        do {
            try defaults.set(JSONEncoder().encode(value), forKey: key)
        } catch {
            Log.store.error("\(key, privacy: .public) encode failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    var isSignedIn: Bool {
        !accounts.isEmpty || pendingLegacyToken != nil
    }

    init() {
        defaults = .standard
        if let stored = defaults.string(forKey: Self.apiBaseURLKey), let url = URL(string: stored) {
            apiBaseURL = url
        } else {
            apiBaseURL = AppConfig.defaultAPIBaseURL
        }
        // Restore the last-used OAuth client ID, falling back to the build's baked one (blank on
        // self-host builds). Public identifier, so UserDefaults is fine.
        oauthClientID = defaults.string(forKey: Self.oauthClientIDKey) ?? AppConfig.bakedClientID ?? ""
        // Validate the restored value against the known intervals so a corrupt/legacy default
        // (e.g. a tiny 0.001 that would spin the loop hot) can't reach the poll loop.
        if defaults.object(forKey: Self.pollIntervalKey) != nil,
           let stored = PollInterval(rawValue: defaults.double(forKey: Self.pollIntervalKey))
        {
            pollInterval = stored.rawValue
        } else {
            pollInterval = PollInterval.m1.rawValue
        }
        // Key absent → first launch, seed defaults. Key present (even if `[]`) → the user
        // may have intentionally cleared the list, so respect it and don't resurrect defaults.
        if let data = defaults.data(forKey: Self.savedQueriesKey) {
            do {
                savedQueries = try JSONDecoder().decode([SearchQuery.Section].self, from: data)
            } catch {
                Log.store.error("saved queries decode failed: \(error.localizedDescription, privacy: .public)")
                savedQueries = SearchQuery.defaults
            }
        } else {
            savedQueries = SearchQuery.defaults
        }
        // Watchlist starts empty — the Actions/Releases tabs prompt the user to add repos.
        if let data = defaults.data(forKey: Self.watchlistKey) {
            do {
                watchlist = try JSONDecoder().decode([String].self, from: data)
            } catch {
                Log.store.error("watchlist decode failed: \(error.localizedDescription, privacy: .public)")
                watchlist = []
            }
        } else {
            watchlist = []
        }
        restorePreferences()
        restorePersistedAccounts()
        startPolling()
    }

    /// Restore the simple toggle/choice preferences from `defaults`. Absence of a key means
    /// first launch, so each falls back to its inline default (notifications on; badge shows
    /// review-requested only).
    private func restorePreferences() {
        notificationsEnabled = defaults.object(forKey: Self.notificationsEnabledKey) as? Bool ?? true
        notifyInbox = defaults.object(forKey: Self.notifyInboxKey) as? Bool ?? true
        notifySections = defaults.object(forKey: Self.notifySectionsKey) as? Bool ?? true
        notifyChecks = defaults.object(forKey: Self.notifyChecksKey) as? Bool ?? true
        if let stored = defaults.stringArray(forKey: Self.badgeSourcesKey) {
            badgeSources = Set(stored)
        }
    }

    /// Restore connected accounts (metadata only; tokens stay in the Keychain), the account
    /// filter (dropped if it no longer names a live account), and stage any legacy single-token
    /// credential for migration on the next refresh.
    private func restorePersistedAccounts() {
        if let data = defaults.data(forKey: Self.accountsKey) {
            do {
                accounts = try JSONDecoder().decode([Account].self, from: data)
            } catch {
                Log.store.error("accounts decode failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        if let filter = defaults.string(forKey: Self.accountFilterKey),
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
    /// factory, and a constant token per account. Persistence goes to an isolated, wiped
    /// defaults suite — never the real app domain (a suite of `AppStore` tests once overwrote
    /// the live account list and client ID through the `didSet` writes).
    init(
        apiBaseURL: URL,
        accounts: [Account],
        makeAPI: @escaping @Sendable (URL, String) -> GitHubAPI,
        token: String = "test-token"
    ) {
        let suiteName = "dev.lanfermann.gbar.tests"
        let suite = UserDefaults(suiteName: suiteName) ?? .standard
        suite.removePersistentDomain(forName: suiteName)
        defaults = suite
        self.apiBaseURL = apiBaseURL
        oauthClientID = ""
        pollInterval = PollInterval.off.rawValue
        savedQueries = SearchQuery.defaults
        watchlist = []
        self.accounts = accounts
        self.makeAPI = makeAPI
        tokenForAccount = { _ in token }
    }
    #endif
}

// MARK: - Refresh

extension AppStore {
    /// Single-flight refresh. Concurrent callers coalesce onto one in-flight run so their
    /// `@MainActor`-interleaved awaits can't clobber each other's partial state (#10).
    ///
    /// Pass `force: true` when the caller has just changed credential/account state that the
    /// in-flight run was built from a now-stale snapshot of (e.g. `reconnect` after storing a
    /// fresh token). Force supersedes the in-flight run — cancels it and starts a fresh one —
    /// rather than coalescing onto a result computed from the old token.
    func refresh(force: Bool = false) async {
        if let existing = refreshTask {
            // Force supersedes the stale run (cancel + let it unwind — it drops its writes on
            // `Task.isCancelled`); otherwise coalesce onto it and return.
            if force { existing.cancel() }
            await existing.value
            if !force { return }
            // Two concurrent `force` callers both awaited `existing`; the main actor resumes them
            // one at a time, so by the time this one runs a peer may have already installed a fresh
            // run (there's no suspension between its resume and its `refreshTask = task`). Coalesce
            // onto that run rather than starting a third overlapping wave.
            if let current = refreshTask, current != existing {
                await current.value
                return
            }
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performRefresh()
        }
        refreshTask = task
        await task.value
        // Only clear if a newer run (a concurrent `force` refresh) hasn't already replaced ours.
        if let current = refreshTask, current == task { refreshTask = nil }
    }

    /// Refresh every section for every account and merge the results. Accounts are fetched
    /// concurrently in a `TaskGroup`; the merged data is kept whole and the account filter is
    /// applied only in the view-facing projections, so switching accounts needs no refetch.
    private func performRefresh() async {
        let legacyExpired = await migrateLegacyCredentialIfNeeded()
        guard !accounts.isEmpty else {
            // A legacy token that was definitively rejected (401) is dropped in the migration, so
            // `isSignedIn` falls to false and the UI shows the sign-in prompt rather than a
            // permanent first-load skeleton. Surface why, and mark the first load complete.
            if legacyExpired {
                lastErrorMessage = "Your saved sign-in expired — please sign in again."
            }
            // End the first-load skeleton only when we're genuinely signed out now (the dead
            // legacy token was dropped). A still-pending token after a *transient* migration
            // failure keeps the skeleton so the next poll's retry isn't superseded by an empty state.
            if !isSignedIn { hasLoaded = true }
            return
        }
        isRefreshing = true
        lastErrorMessage = nil
        // Clear both halves of the expired-session state together — leaving `expiredAccountID`
        // behind would let `expiredAccount` resolve a stale account mid-refresh, before
        // `applyErrorState` recomputes the pair.
        sessionExpired = false
        expiredAccountID = nil
        rateLimitedUntil = nil
        defer { isRefreshing = false }

        // One API client per account (skipping any whose token has gone missing), reused for
        // both the section load and CI hydration.
        let accountAPIs = currentAccountAPIs()
        guard !accountAPIs.isEmpty else {
            hasLoaded = true
            return
        }

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

        // Superseded while fetching — sign-out cancelled us, or a `force` refresh replaced us?
        // Drop our writes instead of clobbering fresher (or signed-out) state, mirroring the
        // `checksGeneration` staleness guard used for CI hydration.
        guard !Task.isCancelled else { return }

        // Diff against the previous poll and fire banners for new section items / inbox threads
        // before the merged data replaces the store's state. Both read `loadsByAccount` directly
        // so they can tell a genuinely-empty result apart from a failed one (which must not
        // advance/seed that account's baseline). CI-status banners fire later, at hydration
        // completion (see `hydrateChecks`).
        notifyNewSectionItems(loads: loadsByAccount, queries: queries)
        notifyNewInboxItems(loads: loadsByAccount)

        sections = mergeSections(loadsByAccount, queries: queries)
        notifications = mergeNotifications(loadsByAccount)
        mergeStarred(loadsByAccount)
        applyErrorState(from: loadsByAccount)

        kickOffHydration(accountAPIs: accountAPIs)
        hasLoaded = true
    }

    /// Fire the non-blocking CI + per-repo-feed hydration waves, unless we're rate-limited — those
    /// are an N+1 over the PR list, so skipping them while limited avoids digging the hole deeper
    /// (the sections/notifications that already loaded still show; feeds rehydrate next poll).
    private func kickOffHydration(accountAPIs: [(account: Account, api: GitHubAPI)]) {
        if rateLimitedUntil.map({ $0 > Date() }) == true { return }
        let apis = Dictionary(uniqueKeysWithValues: accountAPIs.map { ($0.account.id, $0.api) })
        hydrateChecks(for: sections, apis: apis)
        hydrateRepoFeeds(apis: apis)
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
    /// Records which account expired (first in account order) so the prompt can offer a
    /// per-account "Reconnect <login>" rather than a global sign-in.
    private func applyErrorState(from loads: [Account.ID: AccountLoad]) {
        let expired = accounts.first { loads[$0.id]?.sessionExpired == true }
        sessionExpired = expired != nil
        expiredAccountID = expired?.id
        // Back off to the latest reset any account reported (nil clears a prior limit).
        rateLimitedUntil = loads.values.compactMap(\.rateLimitedUntil).max()
        if expired != nil {
            lastErrorMessage = "Session expired — reconnect in Settings."
        } else if let until = rateLimitedUntil {
            lastErrorMessage = AuthErrorCopy.rateLimitMessage(until: until)
        } else {
            lastErrorMessage = loads.values.compactMap(\.errorMessage).first
        }
    }

    /// Flag one account's session as expired — used by quick actions on a 401 so the reconnect
    /// prompt can offer a per-account "Reconnect <login>", matching the refresh path. Lives here
    /// because `expiredAccountID` has a `private(set)` setter scoped to this file.
    func markSessionExpired(accountID: Account.ID) {
        sessionExpired = true
        expiredAccountID = accountID
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
            // A dead token here means the same thing as on a quick action — flag the account
            // expired and prompt a reconnect rather than a generic, dead-end failure message.
            if case .http(401) = error as? GitHubClient.ClientError {
                markSessionExpired(accountID: item.account.id)
                lastErrorMessage = "Session expired — reconnect in Settings."
            } else {
                lastErrorMessage = "Couldn't mark notification as read."
            }
            Log.network.error("mark notification read failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Drop every loaded notification belonging to `accountID` — the mutating half of the bulk
    /// mark-read flow, kept here because `notifications` has a `private(set)` setter scoped to
    /// this file.
    func dropNotifications(forAccount accountID: Account.ID) {
        notifications.removeAll { $0.account.id == accountID }
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
        repoFeedsTask?.cancel()
        repoFeedsGeneration += 1
        lastErrorMessage = nil
        sessionExpired = false
        expiredAccountID = nil
        reauthStatus = .idle
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
        repoFeedsTask?.cancel()
        repoFeedsGeneration += 1
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
        prGates = prGates.filter { $0.key.accountID != id }
        prGateSeq = prGateSeq.filter { $0.key.accountID != id }
        repoMergeInfo = repoMergeInfo.filter { !$0.key.hasPrefix("\(id)\n") }
        starredByAccount[id] = nil
        actionRuns.removeAll { $0.account.id == id }
        releases.removeAll { $0.account.id == id }
        if accounts.isEmpty {
            resetSignedOutState()
        } else {
            // Drop just this account's notification baselines so re-adding it re-seeds silently
            // and the sets don't leak entries for a removed account.
            pruneNotificationBaselines(accountID: id)
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
        // Cancel any in-flight refresh so its post-fetch writes (and its `hasLoaded = true`) can't
        // land on the now-signed-out store — it drops them on `Task.isCancelled`. See #10.
        refreshTask?.cancel()
        refreshTask = nil
        checksTask?.cancel()
        checksTask = nil
        mergeReadinessTask?.cancel() // its loop also bails on the now-false `isSignedIn`
        mergeReadinessTask = nil
        checksGeneration += 1
        repoFeedsTask?.cancel()
        repoFeedsTask = nil
        repoFeedsGeneration += 1
        sections = []
        notifications = []
        prChecks = [:]
        prGates = [:]
        prGateSeq = [:]
        prHydrationMark = [:]
        repoMergeInfo = [:]
        starredByAccount = [:]
        actionRuns = []
        releases = []
        hasLoadedRepoFeeds = false
        hasLoaded = false
        sessionExpired = false
        expiredAccountID = nil
        reauthStatus = .idle
        lastErrorMessage = nil
        // Reset every notification baseline so the next sign-in re-seeds silently instead of
        // firing a banner for every pre-existing item.
        resetNotificationBaselines()
        // Drop any un-migrated legacy token too, so removing the last account can't leave
        // `isSignedIn` stuck true (with zero accounts) on a revoked/never-migrated credential.
        pendingLegacyToken = nil
    }

    private func persistAccounts() {
        do {
            let data = try JSONEncoder().encode(accounts)
            defaults.set(data, forKey: Self.accountsKey)
        } catch {
            Log.store.error("accounts encode failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Resolve a legacy single-token credential into an `Account`. Idempotent (no-op once the
    /// pending token is cleared) and non-destructive: on failure the legacy token is left in
    /// place so a later refresh can retry. Device flow has no refresh token, so we don't know
    /// the original `kind` — default to `.oauth` (the common case).
    /// Returns `true` when a pending legacy token was *definitively rejected* (a 401) — the caller
    /// uses that to surface an actionable sign-in state instead of retrying a dead token forever.
    /// A transient failure (network/5xx) returns `false` and leaves the token staged for retry.
    @discardableResult
    func migrateLegacyCredentialIfNeeded() async -> Bool {
        guard let token = pendingLegacyToken else { return false }
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
            return false
        } catch {
            Log.auth.error("legacy token migration failed: \(error.localizedDescription, privacy: .public)")
            // A rejected token can never succeed on retry, and silently re-attempting it every poll
            // leaves the app stuck showing a first-load skeleton (isSignedIn stays true with no
            // account, hasLoaded never flips). Drop it so the sign-in prompt can take over.
            if case .http(401) = error as? GitHubClient.ClientError {
                deleteToken(Credential.keychainKey)
                pendingLegacyToken = nil
                return true
            }
            return false
        }
    }
}
