import Foundation

/// One search result tagged with the account it came from. Aggregation merges items from
/// every signed-in account into a single section, so each item must remember its owner
/// (for provenance badges, per-account CI keys, and account-scoped filtering).
struct AccountItem: Identifiable {
    let account: Account
    let issue: SearchIssue

    /// Composite of account id + issue id — a bare `issue.id` (an `Int`) can collide across
    /// hosts, so scope it by account for a stable SwiftUI identity.
    var id: String {
        "\(account.id)#\(issue.id)"
    }
}

/// One notification tagged with its owning account — `markRead` needs the right account's
/// token, and the row shows which account it belongs to.
struct AccountNotification: Identifiable {
    let account: Account
    let notification: GitHubNotification

    var id: String {
        "\(account.id)#\(notification.id)"
    }
}

/// Composite key for `AppStore.prChecks`: PR ids are per-host, so a bare `Int` would collide
/// when the same numeric id exists on two accounts.
struct PRCheckKey: Hashable {
    let accountID: Account.ID
    let prID: Int
}

/// A default/saved query resolved to its current results, aggregated across accounts.
struct LoadedSection: Identifiable {
    let id: String
    let title: String
    let items: [AccountItem]
    /// Which tab the section renders under, carried over from `SearchQuery.Section.resolvedKind`.
    let kind: SearchQuery.Section.Kind
}

/// The rolled-up CI status for one PR plus its per-check detail rows, hydrated lazily
/// after a refresh (see `AppStore.prChecks`).
struct PRChecks {
    let status: CIStatus
    let checks: [CheckRow.Model]
}

/// The result of loading one account's sections + inbox, gathered off the main actor and
/// merged back on it. Value type with `Sendable` members → implicit `Sendable`.
struct AccountLoad {
    let account: Account
    /// Section results keyed by `SearchQuery.Section.id`. A missing key means that query
    /// failed for this account (so the merged section can still show other accounts' rows).
    var sections: [String: [SearchIssue]]
    var notifications: [GitHubNotification]
    /// Whether the `/notifications` fetch succeeded this poll. The notification diff advances
    /// (and seeds) the inbox baseline only for accounts that loaded, so a transient inbox
    /// failure can't drop threads from the baseline and re-fire them as "new" on recovery.
    var notificationsSucceeded: Bool
    var sessionExpired: Bool
    var errorMessage: String?
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
