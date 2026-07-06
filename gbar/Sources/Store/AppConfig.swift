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

    /// Derives the device-flow web host (where users authorize) from an API base URL.
    ///
    /// - `api.github.com` maps to `https://github.com`.
    /// - Enterprise API URLs (`https://ghe.example.com/api/v3`) drop the `/api` path,
    ///   keeping scheme + host.
    /// - Anything we can't parse falls back to the public `https://github.com`.
    static func webBaseURL(forAPI apiBaseURL: URL) -> URL {
        let fallback = URL(string: "https://github.com") ?? URL(fileURLWithPath: "/")
        guard let components = URLComponents(url: apiBaseURL, resolvingAgainstBaseURL: false),
              let host = components.host, !host.isEmpty
        else { return fallback }

        let scheme = components.scheme ?? "https"
        // Public GitHub: api.github.com -> github.com.
        if host == "api.github.com" {
            return URL(string: "\(scheme)://github.com") ?? fallback
        }
        // Enterprise: keep scheme + host (+ port), drop the /api(/v3) path.
        let port = components.port.map { ":\($0)" } ?? ""
        return URL(string: "\(scheme)://\(host)\(port)") ?? fallback
    }

    /// Derives the GraphQL endpoint from a REST API base URL — a different host/path than REST.
    ///
    /// - `api.github.com` (REST) maps to `https://api.github.com/graphql`.
    /// - Enterprise **Cloud with data residency** (`https://api.<tenant>.ghe.com`) maps to
    ///   `https://api.<tenant>.ghe.com/graphql` — GraphQL lives at `/graphql` on the same
    ///   `api.`-prefixed host, with no `/api` segment (mirrors public GitHub's layout).
    /// - Enterprise **Server** (`https://ghe.example.com/api/v3`) maps to
    ///   `https://ghe.example.com/api/graphql` (same host, `/api/graphql` in place of `/api/v3`).
    /// - Anything we can't parse falls back to the public `https://api.github.com/graphql`.
    static func graphQLURL(forAPI apiBaseURL: URL) -> URL {
        let fallback = URL(string: "https://api.github.com/graphql") ?? URL(fileURLWithPath: "/")
        guard let components = URLComponents(url: apiBaseURL, resolvingAgainstBaseURL: false),
              let host = components.host, !host.isEmpty
        else { return fallback }

        let scheme = components.scheme ?? "https"
        let port = components.port.map { ":\($0)" } ?? ""
        // An `api.`-prefixed host (public `api.github.com` or GHE Cloud data-residency
        // `api.<tenant>.ghe.com`) serves GraphQL at `/graphql`; a path-based Enterprise
        // Server host (`ghe.example.com/api/v3`) serves it at `/api/graphql`.
        let path = host.hasPrefix("api.") ? "/graphql" : "/api/graphql"
        return URL(string: "\(scheme)://\(host)\(port)\(path)") ?? fallback
    }

    private static func value(for key: String) -> String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
