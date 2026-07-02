import Foundation

/// Pure, side-effect-free diffing for desktop notifications. Deliberately kept apart from
/// `NotificationService` (which needs `UNUserNotificationCenter`) and from `AppStore` (which
/// owns the stateful, account-aware baselines) so the "what changed since the last poll" set
/// math is unit-testable in isolation.
///
/// Everything is keyed by a composite of the owning account so identical numeric/string ids on
/// two different hosts never collide (a PR `#42` on github.com is not `#42` on an Enterprise
/// host). Baseline advancement, per-account seeding, and the on/off toggles live in `AppStore`.
enum NotificationDiff {
    // MARK: - Inbox

    /// Composite baseline key for one inbox thread: `"<account.id>\n<notification.id>"`.
    static func inboxKey(account: Account, notification: GitHubNotification) -> String {
        "\(account.id)\n\(notification.id)"
    }

    /// Inbox threads that are unread now and whose composite key wasn't in the previous unread
    /// set — the items to notify about. Tracking the *unread* key-set (rather than every key
    /// ever seen) means a thread that flips read→unread again on new activity re-notifies, while
    /// a thread already surfaced this session stays quiet.
    static func newNotifications(
        previousUnreadKeys: Set<String>,
        current: [AccountNotification]
    )
    -> [AccountNotification] {
        current.filter {
            $0.notification.unread
                && !previousUnreadKeys.contains(inboxKey(account: $0.account, notification: $0.notification))
        }
    }

    /// The unread composite-key set for a batch of one account's notifications, to fold into the
    /// carried-forward baseline.
    static func unreadKeys(account: Account, notifications: [GitHubNotification]) -> Set<String> {
        Set(notifications.lazy.filter(\.unread).map { inboxKey(account: account, notification: $0) })
    }

    // MARK: - Sections

    /// Composite baseline key for one section item: `"<account.id>\n<issue.id>"`. Shared across
    /// every section, so an item appearing in two sections dedupes to one banner.
    static func sectionItemKey(account: Account, issue: SearchIssue) -> String {
        "\(account.id)\n\(issue.id)"
    }

    /// The account-tagged items whose composite key wasn't present last poll — deduped across
    /// sections (the same item can appear in several) while preserving first-seen order.
    static func newSectionItems(
        previousKeys: Set<String>,
        items: [AccountItem]
    )
    -> [AccountItem] {
        var seen = Set<String>()
        var result: [AccountItem] = []
        for item in items {
            let key = sectionItemKey(account: item.account, issue: item.issue)
            guard !previousKeys.contains(key), seen.insert(key).inserted else { continue }
            result.append(item)
        }
        return result
    }

    // MARK: - CI status

    /// Whether a PR's CI status changed in a way worth a banner: it reached a terminal
    /// success/failure that differs from what we last saw. Pending/neutral churn and the
    /// first-ever observation (`previous == nil`) stay quiet, so a fresh hydration or a
    /// newly-appeared PR doesn't spam.
    static func checkStatusChanged(previous: CIStatus?, new: CIStatus) -> Bool {
        guard new == .success || new == .failure else { return false }
        guard let previous else { return false }
        return previous != new
    }
}
