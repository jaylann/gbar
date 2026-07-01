import Foundation

/// How a request authenticates to GitHub. Both resolve to a bearer token on the wire;
/// the distinction is only how the token was obtained (OAuth device flow vs. a PAT the
/// user pasted).
struct Credential: Equatable {
    enum Kind: String, Codable {
        case oauth
        case personalAccessToken
    }

    let kind: Kind
    let token: String

    /// Keychain account key under which the active token is stored.
    static let keychainKey = "github.token"
}
