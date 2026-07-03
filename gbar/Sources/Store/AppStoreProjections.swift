import Foundation

// MARK: - View-facing (account-filtered) projections

/// Read-only projections the menu/views render from — account-filtered sections, tab counts,
/// starred lookups, and per-PR CI hydration accessors. Pure reads over the store's state, split
/// out of `AppStore.swift` to keep that file within SwiftLint's `file_length`.
extension AppStore {
    /// Apply the active account filter to a set of tagged items. `nil` filter = pass-through.
    func visible(_ items: [AccountItem]) -> [AccountItem] {
        guard let filter = accountFilter else { return items }
        return items.filter { $0.account.id == filter }
    }

    /// Re-derive the cached `prSections`/`issueSections` from `sections` + `accountFilter`. Called
    /// from the `didSet`s on those inputs, never per view read.
    func recomputeSectionProjections() {
        prSections = filteredSections(kind: .prs)
        issueSections = filteredSections(kind: .issues)
    }

    /// Re-derive the cached `visibleNotifications` from `notifications` + `accountFilter`.
    func recomputeNotificationProjection() {
        guard let filter = accountFilter else {
            visibleNotifications = notifications
            return
        }
        visibleNotifications = notifications.filter { $0.account.id == filter }
    }

    /// Per-source counts for the menu-bar badge, in `BadgeSource.allCases` order, restricted to
    /// the user-selected `badgeSources`. Section sources are **deduped by item across all of
    /// them** — the first source to claim a PR/issue owns it — so a PR that is both assigned and
    /// review-requested is counted once and the breakdown sums exactly to `badgeCount`. The
    /// `.inbox` source contributes the **global** unread count (not the account-filtered
    /// projection), since the badge reflects app-wide state, not a transient view scope.
    /// (`total` rather than `count` so SwiftLint's `empty_count` rule doesn't mistake the Int
    /// field for a collection-emptiness check.)
    var badgeBreakdown: [(source: BadgeSource, total: Int)] {
        var seen: Set<AccountItem.ID> = []
        return BadgeSource.allCases.compactMap { source in
            guard badgeSources.contains(source.rawValue) else { return nil }
            let total: Int
            if source == .inbox {
                total = notifications.filter(\.notification.unread).count
            } else {
                let items = sections.first { $0.id == source.rawValue }?.items ?? []
                total = items.reduce(0) { seen.insert($1.id).inserted ? $0 + 1 : $0 }
            }
            return (source, total)
        }
    }

    /// The number shown next to the menu-bar icon — the deduped sum of the selected badge
    /// sources. Intentionally global (ignores the in-menu account filter).
    var badgeCount: Int {
        badgeBreakdown.reduce(0) { $0 + $1.total }
    }

    /// Hover-tooltip / accessibility text spelling out what the badge number means: a full
    /// sentence for a single active source, a `·`-joined breakdown for several, or a calm
    /// "nothing needs your attention" when the count is zero.
    var badgeTooltip: String {
        let active = badgeBreakdown.filter { $0.total > 0 }
        guard let first = active.first else { return "gbar — nothing needs your attention" }
        if active.dropFirst().isEmpty { return first.source.soloTooltip(first.total) }
        return active.map { "\($0.total) \($0.source.shortLabel)" }.joined(separator: " · ")
    }

    func filteredSections(kind: SearchQuery.Section.Kind) -> [LoadedSection] {
        sections
            .filter { $0.kind == kind }
            .map { LoadedSection(id: $0.id, title: $0.title, items: visible($0.items), kind: $0.kind) }
    }

    /// Total PR-section items (filtered) — the count shown on the PRs tab.
    var prCount: Int {
        prSections.reduce(0) { $0 + $1.items.count }
    }

    /// Total issue-section items (filtered) — the count shown on the Issues tab.
    var issueCount: Int {
        issueSections.reduce(0) { $0 + $1.items.count }
    }

    /// Unread notifications (filtered) — the count shown on the Notifications tab.
    var unreadNotificationCount: Int {
        visibleNotifications.filter(\.notification.unread).count
    }

    /// Whether the repo an item sits on is starred by that item's account (case-insensitive).
    func isStarred(_ item: AccountItem) -> Bool {
        starredByAccount[item.account.id]?.contains(item.issue.repositorySlug.lowercased()) ?? false
    }

    /// Whether the repo a notification belongs to is starred by its account (case-insensitive).
    func isStarred(_ item: AccountNotification) -> Bool {
        starredByAccount[item.account.id]?.contains(item.notification.repository.fullName.lowercased()) ?? false
    }

    /// The hydrated CI status/detail for a tagged PR item, if any.
    func checks(for item: AccountItem) -> PRChecks? {
        prChecks[PRCheckKey(accountID: item.account.id, prID: item.issue.id)]
    }

    /// The hydrated action gate for a tagged PR item, if any (`nil` = not yet hydrated).
    func gate(for item: AccountItem) -> PRGate? {
        prGates[PRCheckKey(accountID: item.account.id, prID: item.issue.id)]
    }
}
