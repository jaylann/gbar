import Foundation
import Observation

/// A default/saved query resolved to its current results.
struct LoadedSection: Identifiable {
    let id: String
    let title: String
    let items: [SearchIssue]
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

    /// GitHub API base — defaults to the build's configured host, overridable for Enterprise.
    var apiBaseURL: URL {
        didSet { UserDefaults.standard.set(apiBaseURL.absoluteString, forKey: Self.apiBaseURLKey) }
    }

    private static let apiBaseURLKey = "gbar.apiBaseURL"

    var isSignedIn: Bool {
        credential != nil
    }

    init() {
        if let stored = UserDefaults.standard.string(forKey: Self.apiBaseURLKey), let url = URL(string: stored) {
            apiBaseURL = url
        } else {
            apiBaseURL = AppConfig.defaultAPIBaseURL
        }
        if let token = KeychainStore.get(Credential.keychainKey) {
            credential = Credential(kind: .oauth, token: token)
        }
    }

    func signIn(token: String, kind: Credential.Kind) {
        do {
            try KeychainStore.set(token, for: Credential.keychainKey)
            credential = Credential(kind: kind, token: token)
        } catch {
            lastErrorMessage = "Couldn't save credential to Keychain."
            Log.auth.error("keychain save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func signOut() {
        KeychainStore.remove(Credential.keychainKey)
        credential = nil
        sections = []
    }

    /// Refresh every default section. Kept intentionally simple for v1 — sequential fetch,
    /// no checks/notifications yet (those are on the roadmap).
    func refresh() async {
        guard let credential else { return }
        isRefreshing = true
        lastErrorMessage = nil
        sessionExpired = false
        defer { isRefreshing = false }

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
