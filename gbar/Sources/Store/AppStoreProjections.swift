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

    /// Count of actionable PRs — review-requested plus assigned — shown on the menu-bar icon.
    /// Intentionally global (ignores the in-menu account filter): the icon reflects app-wide
    /// state, not a transient view scope.
    var badgeCount: Int {
        let actionable: Set = ["review-requested", "assigned-prs"]
        return sections.filter { actionable.contains($0.id) }.reduce(0) { $0 + $1.items.count }
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
