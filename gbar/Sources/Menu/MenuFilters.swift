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
            // Tab-specific chips cross-fade when the tab changes (driven by the
            // `.animation(value: selectedTab)` on `chipsRow` at the call site).
            if selectedTab == .prs {
                FilterChip(title: "All", isOn: chipBinding(.all)).transition(.opacity)
                FilterChip(title: "Failing CI", symbol: "xmark.octagon", isOn: chipBinding(.failingCI))
                    .transition(.opacity)
                FilterChip(title: "Needs review", symbol: "eye", isOn: chipBinding(.needsReview)).transition(.opacity)
            }
            if selectedTab == .notifications {
                FilterChip(title: "All", isOn: inboxChipBinding(.all)).transition(.opacity)
                FilterChip(title: "Review requested", symbol: "eye", isOn: inboxChipBinding(.reviewRequested))
                    .transition(.opacity)
                FilterChip(title: "Mentioned", symbol: "at", isOn: inboxChipBinding(.mentioned)).transition(.opacity)
                FilterChip(title: "Assigned", symbol: "person", isOn: inboxChipBinding(.assigned)).transition(.opacity)
            }
            FilterChip(title: "Starred", symbol: "star", isOn: starredBinding)
            Spacer(minLength: 0)
            if selectedTab == .notifications, !isFiltering, store.unreadNotificationCount > 0 {
                Button { Task { await store.markAllRead() } } label: {
                    DoubleCheckmarkIcon()
                }
                .buttonStyle(GBButtonStyle(variant: .icon))
                .gbTooltip("Mark all as read", edge: .bottom)
                .accessibilityLabel("Mark all as read")
            }
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.bottom, Theme.Spacing.sm)
    }

    /// Drives a `FilterChip` as a radio button: turning one on selects that mode; turning the
    /// active one off resets to `.all`. The list diff is animated here at the toggle (rather than
    /// via an ambient `.animation` on the list) so the rows fade/reflow on a deliberate action
    /// without a persistent modifier slowing scroll — the same tactic as `MenuRows.setMode`.
    private func chipBinding(_ filter: PRFilter) -> Binding<Bool> {
        Binding(
            get: { prFilter == filter },
            set: { isOn in
                withAnimation(Motion.respecting(reduceMotion, Motion.spring)) {
                    prFilter = isOn ? filter : .all
                }
            }
        )
    }

    /// Radio-style binding for the Inbox reason chips, mirroring `chipBinding`.
    private func inboxChipBinding(_ reason: InboxReason) -> Binding<Bool> {
        Binding(
            get: { inboxReason == reason },
            set: { isOn in
                withAnimation(Motion.respecting(reduceMotion, Motion.spring)) {
                    inboxReason = isOn ? reason : .all
                }
            }
        )
    }

    /// A plain on/off binding for the cross-tab "Starred" toggle. Built here (rather than passing
    /// `$starredOnly` across files) so `starredOnly` can stay a `@State` on the view.
    private var starredBinding: Binding<Bool> {
        Binding(
            get: { starredOnly },
            set: { newValue in
                withAnimation(Motion.respecting(reduceMotion, Motion.spring)) { starredOnly = newValue }
            }
        )
    }
}
