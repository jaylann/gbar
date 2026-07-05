import Foundation

/// A guard for opening URLs that originate from a GitHub host. Issue/PR/notification links come
/// back from the configured API host, which on a self-hosted or Enterprise instance is only a
/// semi-trusted origin — a compromised or hostile host could return a `file:`, `javascript:`, or
/// custom-scheme URL. Only `http`/`https` links are ever handed to `openURL` / `NSWorkspace`, so
/// such a URL can never launch a local file or another app.
enum WebLink {
    /// Parse `string` into a URL, returning it only if it's an `http(s)` web link.
    static func parse(_ string: String?) -> URL? {
        guard let string else { return nil }
        return sanitize(URL(string: string))
    }

    /// Pass a pre-built URL through only if it's an `http(s)` web link.
    static func sanitize(_ url: URL?) -> URL? {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return nil
        }
        return url
    }
}
