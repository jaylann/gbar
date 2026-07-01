import Foundation

/// Bridges the wire model (`GitHubNotification`) to the design-system row model
/// (`NotificationRow.Model`) and derives a best-effort browser URL. Kept out of both the
/// model and the view so the mapping vocabulary lives in one place.
extension NotificationRow.Model {
    /// Map a `/notifications` thread into the row's display model. Reason strings and subject
    /// types follow the REST API's vocabulary; unknown values fall back to sensible defaults.
    init(_ notification: GitHubNotification) {
        self.init(
            id: notification.id,
            repo: notification.repository.fullName,
            title: notification.subject.title,
            reason: Self.reason(from: notification.reason),
            date: notification.updatedAt,
            isUnread: notification.unread,
            symbol: Self.symbol(forSubjectType: notification.subject.type)
        )
    }

    /// GitHub notification `reason` string → display reason. Unknown reasons read as a comment.
    static func reason(from raw: String) -> Reason {
        switch raw {
        case "review_requested": .reviewRequested
        case "mention": .mention
        case "assign": .assigned
        case "state_change": .stateChange
        case "comment": .commented
        default: .commented
        }
    }

    /// Subject `type` string → SF Symbol name. Unknown types fall back to the bell.
    static func symbol(forSubjectType type: String) -> String {
        switch type {
        case "PullRequest": "arrow.triangle.pull"
        case "Issue": "smallcircle.circle"
        default: "bell"
        }
    }
}

extension GitHubNotification {
    /// Best-effort browser URL for the thread. `subject.url` is an API URL
    /// (`{apiBase}/repos/{owner}/{name}/pulls/{n}`); we swap in the web host derived from
    /// `apiBaseURL` (via `AppConfig.webBaseURL`, so Enterprise hosts work — its API path
    /// prefix like `/api/v3` is dropped), then keep only the `/repos/`-onward segments the
    /// web UI uses with `pulls`→`pull`. Note: comment threads and some subject types have no
    /// clean web mapping, so this can be `nil` or point at the parent resource — a full
    /// mapping would need the API `latest_comment_url`, deferred.
    func htmlURL(apiBaseURL: URL) -> URL? {
        guard let raw = subject.url,
              let apiURL = URL(string: raw),
              let reposRange = apiURL.path.range(of: "/repos/")
        else { return nil }

        let tail = apiURL.path[reposRange.upperBound...]
            .replacingOccurrences(of: "/pulls/", with: "/pull/")
        var components = URLComponents(url: AppConfig.webBaseURL(forAPI: apiBaseURL), resolvingAgainstBaseURL: false)
        components?.path = "/" + tail
        return components?.url
    }
}
