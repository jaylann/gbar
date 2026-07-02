import Foundation

/// A connected GitHub identity. gbar aggregates results from every account and lets the
/// user scope the menu to one at a time (see `AppStore.accountFilter`).
///
/// The token itself never lives here — it stays in the Keychain under `keychainKey`, keyed
/// by `id`. Only this (non-secret) metadata is persisted as JSON in UserDefaults, because
/// the Keychain isn't cheaply enumerable.
///
/// `id` is the `login`, which is stable and human-meaningful. Note: two accounts with the
/// same login on different hosts (github.com + an Enterprise instance) would collide on
/// `id`/`keychainKey` — an accepted edge case for v1 (see the roadmap).
struct Account: Codable, Identifiable, Hashable {
    /// GitHub login — doubles as the stable identity.
    let login: String
    /// Profile image URL string, as returned by `/user` (`avatar_url`); may be absent.
    let avatarURL: String?
    /// How the token was obtained (OAuth device flow vs. a pasted PAT).
    let kind: Credential.Kind
    /// Per-account API base — lets one account point at github.com and another at Enterprise.
    let apiBaseURL: URL

    var id: String {
        login
    }

    /// Keychain account key for this account's token, namespaced off the legacy single-token
    /// key so migration can re-home the old token without a collision.
    var keychainKey: String {
        Self.keychainKeyPrefix + id
    }

    /// Prefix for per-account Keychain keys — extends the legacy `"github.token"` scheme.
    static let keychainKeyPrefix = "github.token."

    /// Avatar URL parsed for display, if present and valid.
    var avatarImageURL: URL? {
        avatarURL.flatMap(URL.init)
    }
}
