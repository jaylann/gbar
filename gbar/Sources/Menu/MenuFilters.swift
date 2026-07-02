import SwiftUI

/// Single-select filter mode for the PRs tab, surfaced as `FilterChip`s. `needsReview` is
/// approximated by membership in the built-in `review-requested` section (per-item review
/// state isn't loaded, and this pass adds no new API surface).
enum PRFilter {
    case all
    case failingCI
    case needsReview
}

/// Single-select filter mode for the Inbox tab, surfaced as `FilterChip`s. Matches the raw
/// REST `reason` strings directly (rather than `NotificationRow.Model.Reason`) so filtering
/// stays decoupled from the row's display mapping.
enum InboxReason {
    case all
    case reviewRequested
    case mentioned
    case assigned
    func matches(_ raw: String) -> Bool {
        switch self {
        case .all: true
        case .reviewRequested: raw == "review_requested"
        case .mentioned: raw == "mention"
        case .assigned: raw == "assign"
        }
    }
}

/// The popover's filter-chip row and its radio-style bindings, split out of `MenuContentView`
/// to keep that file within the type/file-length limits.
extension MenuContentView {
    /// Filter chips for the active tab. The "Starred" toggle is cross-tab (shown on every tab);
    /// the PR radio chips (All / Failing CI / Needs review) show on PRs, and the Inbox reason
    /// chips — plus a trailing "Mark all read" that only appears with unread present and no
    /// active filter, so "all" is never ambiguous — show on Inbox.
    var chipsRow: some View {
        HStack(spacing: Theme.Spacing.xs) {
            if selectedTab == .prs {
                FilterChip(title: "All", isOn: chipBinding(.all))
                FilterChip(title: "Failing CI", symbol: "xmark.octagon", isOn: chipBinding(.failingCI))
                FilterChip(title: "Needs review", symbol: "eye", isOn: chipBinding(.needsReview))
            }
            if selectedTab == .notifications {
                FilterChip(title: "All", isOn: inboxChipBinding(.all))
                FilterChip(title: "Review requested", symbol: "eye", isOn: inboxChipBinding(.reviewRequested))
                FilterChip(title: "Mentioned", symbol: "at", isOn: inboxChipBinding(.mentioned))
                FilterChip(title: "Assigned", symbol: "person", isOn: inboxChipBinding(.assigned))
            }
            FilterChip(title: "Starred", symbol: "star", isOn: starredBinding)
            Spacer(minLength: 0)
            if selectedTab == .notifications, !isFiltering, store.unreadNotificationCount > 0 {
                Button("Mark all read") { Task { await store.markAllRead() } }
                    .buttonStyle(GBButtonStyle(variant: .ghost))
                    .gbTooltip("Mark all as read", edge: .bottom)
            }
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.bottom, Theme.Spacing.sm)
    }

    /// Drives a `FilterChip` as a radio button: turning one on selects that mode; turning the
    /// active one off resets to `.all`.
    private func chipBinding(_ filter: PRFilter) -> Binding<Bool> {
        Binding(
            get: { prFilter == filter },
            set: { isOn in prFilter = isOn ? filter : .all }
        )
    }

    /// Radio-style binding for the Inbox reason chips, mirroring `chipBinding`.
    private func inboxChipBinding(_ reason: InboxReason) -> Binding<Bool> {
        Binding(
            get: { inboxReason == reason },
            set: { isOn in inboxReason = isOn ? reason : .all }
        )
    }

    /// A plain on/off binding for the cross-tab "Starred" toggle. Built here (rather than passing
    /// `$starredOnly` across files) so `starredOnly` can stay a `@State` on the view.
    private var starredBinding: Binding<Bool> {
        Binding(get: { starredOnly }, set: { starredOnly = $0 })
    }
}
