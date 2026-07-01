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
        if let token = KeychainStore.get(Credential.keychainKey) {
            credential = Credential(kind: .oauth, token: token)
        }
        startPolling()
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

        let client = GitHubClient(baseURL: apiBaseURL, token: credential.token)
        var loaded: [LoadedSection] = []
        for section in SearchQuery.defaults {
            do {
                let items = try await client.searchIssues(section.query)
                loaded.append(LoadedSection(id: section.id, title: section.title, items: items))
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
            }
        }
        sections = loaded
    }
}
