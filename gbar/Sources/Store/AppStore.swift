import Foundation
import Observation

/// A default/saved query resolved to its current results.
struct LoadedSection: Identifiable {
    let id: String
    let title: String
    let items: [SearchIssue]
}

/// How often the store polls GitHub in the background. Raw value is the interval in seconds;
/// `.off` (0) disables auto-refresh entirely.
enum PollInterval: TimeInterval, CaseIterable, Identifiable {
    case off = 0
    case s30 = 30
    case m1 = 60
    case m5 = 300
    case m15 = 900

    var id: TimeInterval {
        rawValue
    }

    var label: String {
        switch self {
        case .off: "Off"
        case .s30: "30 seconds"
        case .m1: "1 minute"
        case .m5: "5 minutes"
        case .m15: "15 minutes"
        }
    }
}

/// Central app state: who's signed in, where the API lives, and the latest results.
/// v1 refreshes by polling `/search/issues`; the store is the seam where richer data
/// sources (checks, notifications, a webhook backend) will attach — see docs/PRODUCT.md.
@MainActor
@Observable
final class AppStore {
    private(set) var credential: Credential?
    private(set) var sections: [LoadedSection] = []
    /// The signed-in user's notification inbox (`GET /notifications`). Loaded best-effort
    /// alongside sections so a notifications failure never blanks the PR/issue lists.
    private(set) var notifications: [GitHubNotification] = []
    var isRefreshing = false
    var lastErrorMessage: String?
    var sessionExpired = false
    /// True once at least one refresh has completed — lets the UI tell "first load"
    /// (show a skeleton) apart from "loaded and genuinely empty" (show caught-up).
    private(set) var hasLoaded = false

    /// GitHub API base — defaults to the build's configured host, overridable for Enterprise.
    var apiBaseURL: URL {
        didSet { UserDefaults.standard.set(apiBaseURL.absoluteString, forKey: Self.apiBaseURLKey) }
    }

    private static let apiBaseURLKey = "gbar.apiBaseURL"

    /// Background auto-refresh cadence in seconds; 0 disables polling. Changing it restarts
    /// the poll loop at the new interval. Persisted like `apiBaseURL`.
    var pollInterval: TimeInterval {
        didSet {
            UserDefaults.standard.set(pollInterval, forKey: Self.pollIntervalKey)
            startPolling()
        }
    }

    private static let pollIntervalKey = "gbar.pollInterval"

    /// The single in-flight poll loop, if any. `@MainActor`-isolated like the rest of the store.
    private var pollTask: Task<Void, Never>?

    /// Builds the API client used by `refresh()`. Overridable so tests can inject a fake
    /// `GitHubAPI` without touching the network; defaults to the live `GitHubClient`.
    @ObservationIgnored
    var makeAPI: @Sendable (_ baseURL: URL, _ token: String) -> GitHubAPI = { GitHubClient(baseURL: $0, token: $1) }

    /// User-editable menu sections. Seeded from `SearchQuery.defaults` on first launch;
    /// persisted as JSON so custom queries and ordering survive relaunches.
    var savedQueries: [SearchQuery.Section] {
        didSet {
            if let data = try? JSONEncoder().encode(savedQueries) {
                UserDefaults.standard.set(data, forKey: Self.savedQueriesKey)
            }
        }
    }

    private static let savedQueriesKey = "gbar.savedQueries"

    var isSignedIn: Bool {
        credential != nil
    }

    /// Count of actionable PRs — review-requested plus assigned — shown on the menu-bar icon.
    var badgeCount: Int {
        let actionable: Set = ["review-requested", "assigned-prs"]
        return sections.filter { actionable.contains($0.id) }.reduce(0) { $0 + $1.items.count }
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
                // Present-but-undecodable blob (e.g. a future schema change): fall back to
                // defaults in memory, but log so it's diagnosable rather than silently lost.
                Log.store.error("saved queries decode failed: \(error.localizedDescription, privacy: .public)")
                savedQueries = SearchQuery.defaults
            }
        } else {
            savedQueries = SearchQuery.defaults
        }
        if let token = KeychainStore.get(Credential.keychainKey) {
            credential = Credential(kind: .oauth, token: token)
        }
        startPolling()
    }

    #if DEBUG
    /// Test-only initializer: constructs a store with a fixed base URL, an already-signed-in
    /// credential, and an injectable API factory — no Keychain/UserDefaults side effects.
    init(apiBaseURL: URL, credential: Credential, makeAPI: @escaping @Sendable (URL, String) -> GitHubAPI) {
        self.apiBaseURL = apiBaseURL
        pollInterval = PollInterval.off.rawValue
        savedQueries = SearchQuery.defaults
        self.credential = credential
        self.makeAPI = makeAPI
    }
    #endif

    /// Append a fresh, empty saved query for the user to fill in. The UUID id keeps it
    /// distinct from the baseline sections (so badge/actionable semantics are unaffected).
    func addSavedQuery() {
        savedQueries.append(SearchQuery.Section(id: UUID().uuidString, title: "", query: ""))
    }

    func deleteSavedQuery(at offsets: IndexSet) {
        savedQueries.remove(atOffsets: offsets)
    }

    func moveSavedQuery(from source: IndexSet, to destination: Int) {
        savedQueries.move(fromOffsets: source, toOffset: destination)
    }

    func signIn(token: String, kind: Credential.Kind) {
        do {
            try KeychainStore.set(token, for: Credential.keychainKey)
            credential = Credential(kind: kind, token: token)
            startPolling()
        } catch {
            lastErrorMessage = "Couldn't save credential to Keychain."
            Log.auth.error("keychain save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func signOut() {
        stopPolling()
        KeychainStore.remove(Credential.keychainKey)
        credential = nil
        sections = []
        notifications = []
        hasLoaded = false
    }

    /// Start (or restart) the background poll loop. Cancels any existing loop first, so it's
    /// safe to call on sign-in, launch, and whenever `pollInterval` changes. A no-op when
    /// signed out or when polling is `.off`.
    private func startPolling() {
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

    /// Refresh every default section. Kept intentionally simple for v1 — sequential fetch,
    /// no checks/notifications yet (those are on the roadmap).
    func refresh() async {
        guard let credential else { return }
        isRefreshing = true
        lastErrorMessage = nil
        sessionExpired = false
        defer {
            isRefreshing = false
            hasLoaded = true
        }

        let api = makeAPI(apiBaseURL, credential.token)
        var loaded: [LoadedSection] = []
        for section in savedQueries {
            // Skip blank/incomplete rows (e.g. a freshly-added query still being edited);
            // GitHub rejects an empty `q` with 422, which would show a persistent error.
            guard section.isRunnable else { continue }
            if let hydrated = await hydrate(section: section, using: api) {
                loaded.append(hydrated)
            }
        }
        sections = loaded
        await loadNotifications(using: api)
    }

    /// Best-effort fetch of the notification inbox. Deliberately separate from section
    /// loading: on failure it surfaces an error (like a partial section failure does) but
    /// leaves `sections` intact, so a flaky `/notifications` call never blanks the PR list.
    private func loadNotifications(using api: GitHubAPI) async {
        do {
            notifications = try await api.notifications()
        } catch {
            if case .http(401) = error as? GitHubClient.ClientError {
                sessionExpired = true
                lastErrorMessage = "Session expired — reconnect in Settings."
            } else if lastErrorMessage == nil {
                // Don't clobber a more important section error already surfaced this refresh.
                lastErrorMessage = "Failed to load notifications."
            }
            Log.network.error("notifications fetch failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Mark a notification thread read on the server, then drop it from the local inbox once
    /// the call succeeds (pessimistic: nothing changes until the server confirms). On failure
    /// the item stays put and the error surfaces via `lastErrorMessage`.
    func markRead(_ notification: GitHubNotification) async {
        guard let credential else { return }
        let api = makeAPI(apiBaseURL, credential.token)
        do {
            try await api.markNotificationRead(threadID: notification.id)
            notifications.removeAll { $0.id == notification.id }
            // Clear any stale error from a prior failed mark-read now that one succeeded.
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = "Couldn't mark notification as read."
            Log.network.error("mark notification read failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Quick actions

    /// Approve a pull request. Builds the API client the same way `refresh()` does, submits an
    /// approving review, and surfaces any failure via `lastErrorMessage`. Approval doesn't
    /// change which lists the PR belongs to, so on success we just clear a stale error.
    func approve(_ item: SearchIssue) async {
        guard let credential else { return }
        let api = makeAPI(apiBaseURL, credential.token)
        do {
            try await api.approvePullRequest(repo: item.repositorySlug, number: item.number)
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = "Failed to approve \(item.repositorySlug) #\(item.number)."
            let ref = "\(item.repositorySlug)#\(item.number)"
            Log.network
                .error("approve failed for \(ref, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Merge a pull request with the chosen strategy. On success the PR is optimistically
    /// removed from every section (it's no longer open, so it would drop out on the next
    /// refresh anyway); failures surface via `lastErrorMessage`.
    func merge(_ item: SearchIssue, method: MergeMethod) async {
        guard let credential else { return }
        let api = makeAPI(apiBaseURL, credential.token)
        do {
            try await api.mergePullRequest(repo: item.repositorySlug, number: item.number, method: method)
            lastErrorMessage = nil
            removeItem(id: item.id)
        } catch {
            lastErrorMessage = "Failed to merge \(item.repositorySlug) #\(item.number)."
            let ref = "\(item.repositorySlug)#\(item.number)"
            Log.network
                .error("merge failed for \(ref, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Drop an item (by id) from every loaded section — used for optimistic UI after a merge.
    private func removeItem(id: Int) {
        sections = sections.map { section in
            LoadedSection(id: section.id, title: section.title, items: section.items.filter { $0.id != id })
        }
    }

    /// Fetch one section, returning it on success or `nil` on failure while performing the
    /// shared 401/other-error handling, logging, and error-message mutation.
    private func hydrate(section: SearchQuery.Section, using api: GitHubAPI) async -> LoadedSection? {
        do {
            let items = try await api.searchIssues(section.query)
            return LoadedSection(id: section.id, title: section.title, items: items)
        } catch {
            if case .http(401) = error as? GitHubClient.ClientError {
                sessionExpired = true
                lastErrorMessage = "Session expired — reconnect in Settings."
            } else {
                lastErrorMessage = "Failed to load \(section.title)."
            }
            Log.network
                .error(
                    "search failed for \(section.id, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            return nil
        }
    }
}
