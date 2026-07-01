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
    /// (`api.github.com/repos/{owner}/{name}/pulls/{n}`); we rewrite the host and the
    /// `/repos/` + `pulls`→`pull` path segments the web UI uses. Note: comment threads and
    /// some subject types have no clean web mapping, so this can be `nil` or point at the
    /// parent resource — a full mapping would need the API `latest_comment_url`, deferred.
    var htmlURL: URL? {
        guard let raw = subject.url, var components = URLComponents(string: raw) else { return nil }
        components.host = components.host?.replacingOccurrences(of: "api.github.com", with: "github.com")
        components.path = components.path
            .replacingOccurrences(of: "/repos/", with: "/")
            .replacingOccurrences(of: "/pulls/", with: "/pull/")
        return components.url
    }
}
