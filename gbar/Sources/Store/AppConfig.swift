import Foundation

/// Build-time configuration injected via Info.plist (from the Tuist xcconfigs).
///
/// `clientID` is blank for self-host builds — the user supplies their own GitHub OAuth
/// App client ID (or a PAT) at runtime. The paid/hosted build ships it pre-filled.
enum AppConfig {
    /// A GitHub OAuth App client ID baked into the build, if any.
    static var bakedClientID: String? {
        value(for: "GHOAuthClientID")
    }

    /// Default GitHub API base URL, overridable at runtime for Enterprise.
    static var defaultAPIBaseURL: URL {
        if let raw = value(for: "GHAPIBaseURL"), let url = URL(string: raw) {
            return url
        }
        // Safe fallback: the public GitHub API.
        return URL(string: "https://api.github.com") ?? URL(fileURLWithPath: "/")
    }

    private static func value(for key: String) -> String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
