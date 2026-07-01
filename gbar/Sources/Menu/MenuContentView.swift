import SwiftUI

/// The top-level domains the menu switches between. PRs and Issues are both
/// `/search/issues`-driven (saved-query sections routed by `LoadedSection.kind`);
/// Notifications is its own data source.
private enum MenuTab: String, CaseIterable {
    case prs
    case issues
    case notifications

    var title: String {
        switch self {
        case .prs: "PRs"
        case .issues: "Issues"
        case .notifications: "Inbox"
        }
    }
}

/// Single-select filter mode for the PRs tab, surfaced as `FilterChip`s. `needsReview` is
/// approximated by membership in the built-in `review-requested` section (per-item review
/// state isn't loaded, and this pass adds no new API surface).
private enum PRFilter {
    case all
    case failingCI
    case needsReview
}

/// The MenuBarExtra window, built on the design system: a consolidated top bar — inline
/// `PRs | Issues | Inbox` tabs on the left, a search toggle and refresh on the right — with
/// a search field that slides in on demand and PR filter chips on the PRs tab. Below it, the
/// active tab's sections (or its own first-load skeleton / caught-up / error state) and a
/// footer. Sign-in prompt when signed out.
struct MenuContentView: View {
    @Bindable var store: AppStore
    @Environment(\.openURL) private var openURL
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @AppStorage("gbar.menu.selectedTab") private var selectedTabRaw = MenuTab.prs.rawValue
    @State private var searchText = ""
    @State private var searchActive = false
    @State private var prFilter: PRFilter = .all
    @FocusState private var searchFocused: Bool

    private var selectedTab: MenuTab {
        MenuTab(rawValue: selectedTabRaw) ?? .prs
    }

    private var tabSelection: Binding<MenuTab> {
        Binding(
            get: { MenuTab(rawValue: selectedTabRaw) ?? .prs },
            set: { selectedTabRaw = $0.rawValue }
        )
    }

    var body: some View {
        PopoverContainer(width: 420, maxHeight: 720) {
            VStack(alignment: .leading, spacing: 0) {
                if store.isSignedIn {
                    header
                    if searchActive {
                        searchRow
                    }
                    if selectedTab == .prs {
                        chipsRow
                    }
                    Divider()
                    tabContent
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    SignInPromptView { openSettingsWindow() }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Divider()
                footer
            }
            // Give the popover a comfortable minimum body so a short list still opens tall,
            // instead of collapsing to just a couple of rows; `maxHeight` on the container caps it.
            .frame(minHeight: 560)
        }
        // Skip if the background poll loop is already refreshing, so opening the menu doesn't
        // overlap an in-flight fetch (see AppStore.startPolling). Note(#10): refresh() itself
        // has no reentrancy guard, so this is a mitigation, not a hard lock.
        .task { if store.isSignedIn, !store.isRefreshing { await store.refresh() } }
    }

    // MARK: Top bar

    private var header: some View {
        HStack(spacing: Theme.Spacing.sm) {
            InlineTabBar(tabs: tabItems, selection: tabSelection)
            Spacer(minLength: Theme.Spacing.sm)
            Button { toggleSearch() } label: {
                Image(systemName: searchActive ? "xmark" : "magnifyingglass")
            }
            .buttonStyle(GBButtonStyle(variant: .icon))
            .gbTooltip(searchActive ? "Close search" : "Search", edge: .bottom)
            Button {
                Task { await store.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(GBButtonStyle(variant: .icon, isLoading: store.isRefreshing))
            .disabled(store.isRefreshing || !store.isSignedIn)
            .gbTooltip("Refresh", edge: .bottom)
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.sm)
    }

    private var searchRow: some View {
        SearchField(placeholder: searchPlaceholder, text: $searchText, focus: $searchFocused)
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.bottom, Theme.Spacing.sm)
            // Slide down from under the top bar so the field reads as "moving in".
            .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var chipsRow: some View {
        HStack(spacing: Theme.Spacing.xs) {
            FilterChip(title: "All", isOn: chipBinding(.all))
            FilterChip(title: "Failing CI", symbol: "xmark.octagon", isOn: chipBinding(.failingCI))
            FilterChip(title: "Needs review", symbol: "eye", isOn: chipBinding(.needsReview))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.bottom, Theme.Spacing.sm)
    }

    private var tabItems: [InlineTabBar<MenuTab>.Tab] {
        MenuTab.allCases.map { .init(tag: $0, title: $0.title, count: badge(for: $0)) }
    }

    /// Reveal or dismiss the search field; focus it on open, clear the query on close.
    private func toggleSearch() {
        withAnimation(Motion.respecting(reduceMotion, Motion.spring)) { searchActive.toggle() }
        if searchActive {
            searchFocused = true
        } else {
            searchText = ""
        }
    }

    /// Just open the Settings scene. The activation dance an `LSUIElement` agent app
    /// needs to make that window take keyboard focus — and the demotion back to a
    /// no-Dock-icon agent on close — is owned entirely by `WindowActivator` inside
    /// `SettingsView`, so it applies however Settings is opened (this button, the
    /// sign-in prompt, or the system ⌘, shortcut).
    private func openSettingsWindow() {
        openSettings()
    }

    /// Unfiltered tab inventory: PR/issue item sums and the unread-notification count. `nil`
    /// (hidden) at zero so the tab stays quiet when it's empty.
    private func badge(for tab: MenuTab) -> Int? {
        let count: Int = switch tab {
        case .prs: store.prCount
        case .issues: store.issueCount
        case .notifications: store.unreadNotificationCount
        }
        return count > 0 ? count : nil
    }

    private var searchPlaceholder: String {
        switch selectedTab {
        case .prs: "Filter pull requests"
        case .issues: "Filter issues"
        case .notifications: "Filter inbox"
        }
    }

    /// Drives a `FilterChip` as a radio button: turning one on selects that mode; turning the
    /// active one off resets to `.all`.
    private func chipBinding(_ filter: PRFilter) -> Binding<Bool> {
        Binding(
            get: { prFilter == filter },
            set: { isOn in prFilter = isOn ? filter : .all }
        )
    }

    // MARK: Per-tab content

    @ViewBuilder
    private var tabContent: some View {
        if store.sessionExpired {
            ErrorStateView(kind: .authExpired, retryTitle: "Open Settings") { openSettingsWindow() }
        } else if !store.hasLoaded {
            // Fill the taller body from the top so the skeleton reads like the list it stands
            // in for, rather than a short block floating mid-popover.
            LoadingView(rows: 8)
                .padding(.horizontal, Theme.Spacing.sm)
                .padding(.vertical, Theme.Spacing.xs)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            switch selectedTab {
            case .prs: prList
            case .issues: issueList
            case .notifications: notificationList
            }
        }
    }

    private var prList: some View {
        let groups = filteredSections(store.prSections) { matchesSearch($0.item) && prPredicate($0) }
        return tabScaffold(isEmpty: groups.isEmpty) {
            emptyState(caughtUpTitle: "No pull requests", caughtUpMessage: "Nothing needs you right now.")
        } content: {
            ForEach(groups, id: \.section.id) { group in
                Section {
                    ForEach(group.items) { item in
                        PRRowItem(store: store, item: item, checks: store.prChecks[item.id]) { url in openURL(url) }
                    }
                } header: {
                    SectionHeader(title: group.section.title, count: group.items.count)
                }
            }
        }
    }

    private var issueList: some View {
        let groups = filteredSections(store.issueSections) { matchesSearch($0.item) }
        return tabScaffold(isEmpty: groups.isEmpty) {
            emptyState(caughtUpTitle: "No issues", caughtUpMessage: "No issues assigned to you.")
        } content: {
            ForEach(groups, id: \.section.id) { group in
                Section {
                    ForEach(group.items) { item in
                        issueRow(item)
                    }
                } header: {
                    SectionHeader(title: group.section.title, count: group.items.count)
                }
            }
        }
    }

    private var notificationList: some View {
        let items = store.notifications.filter { matchesSearch($0) }
        return tabScaffold(isEmpty: items.isEmpty) {
            emptyState(caughtUpTitle: "Inbox zero", caughtUpMessage: "Nothing unread right now.")
        } content: {
            ForEach(items) { notification in
                notificationRow(notification)
            }
        }
    }

    /// The shared per-tab frame: a quiet error banner over the scrolling list when there's
    /// content (a partial failure must never blank a populated tab), an `ErrorStateView` when
    /// empty *because* the last refresh failed, otherwise the tab's own empty state.
    @ViewBuilder
    private func tabScaffold(
        isEmpty: Bool,
        @ViewBuilder empty: () -> some View,
        @ViewBuilder content: () -> some View
    )
    -> some View {
        if !isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                if let message = store.lastErrorMessage {
                    errorBanner(message)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        content()
                    }
                    // A small inset so rows (and the PR disclosure chevron, which sits left of
                    // its row) don't hug the popover edge — HoverRow adds its own inner padding.
                    .padding(.horizontal, Theme.Spacing.sm)
                    .padding(.vertical, Theme.Spacing.xs)
                }
            }
        } else if let message = store.lastErrorMessage {
            ErrorStateView(kind: .generic) { Task { await store.refresh() } }
                .help(message)
        } else {
            empty()
        }
    }

    /// The active tab's empty state: a "no matches" nudge while a search/filter is narrowing,
    /// or the reassuring caught-up reward when the tab is genuinely clear.
    private func emptyState(caughtUpTitle: String, caughtUpMessage: String) -> EmptyStateView {
        if isFiltering {
            EmptyStateView(intent: .neutral, title: "No matches", message: "Try a different search or filter.")
        } else {
            EmptyStateView(intent: .caughtUp, title: caughtUpTitle, message: caughtUpMessage)
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: Theme.Spacing.xs) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.Palette.pending)
            Text(message)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .font(Theme.Typography.caption)
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.xs)
    }

    // MARK: Filtering

    /// Apply a per-item predicate to each section and drop the sections left empty, keeping the
    /// remaining sections intact (routing decision: sections are never split across tabs).
    private func filteredSections(
        _ sections: [LoadedSection],
        matching predicate: ((section: LoadedSection, item: SearchIssue)) -> Bool
    )
    -> [(section: LoadedSection, items: [SearchIssue])] {
        sections
            .map { section in (section, section.items.filter { predicate((section, $0)) }) }
            .filter { !$0.1.isEmpty }
    }

    private var trimmedSearch: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isFiltering: Bool {
        !trimmedSearch.isEmpty || (selectedTab == .prs && prFilter != .all)
    }

    private func matchesSearch(_ item: SearchIssue) -> Bool {
        guard !trimmedSearch.isEmpty else { return true }
        return item.title.localizedCaseInsensitiveContains(trimmedSearch)
            || item.repositorySlug.localizedCaseInsensitiveContains(trimmedSearch)
    }

    private func matchesSearch(_ notification: GitHubNotification) -> Bool {
        guard !trimmedSearch.isEmpty else { return true }
        return notification.subject.title.localizedCaseInsensitiveContains(trimmedSearch)
            || notification.repository.fullName.localizedCaseInsensitiveContains(trimmedSearch)
    }

    private func prPredicate(_ entry: (section: LoadedSection, item: SearchIssue)) -> Bool {
        switch prFilter {
        case .all: true
        case .failingCI: store.prChecks[entry.item.id]?.status == .failure
        case .needsReview: entry.section.id == "review-requested"
        }
    }

    // MARK: Rows

    private func issueRow(_ item: SearchIssue) -> some View {
        Button {
            if let url = URL(string: item.htmlURL) { openURL(url) }
        } label: {
            HoverRow { IssueRow(issue: item) }
        }
        .buttonStyle(.plain)
    }

    /// A notification row: tap the body to open it in the browser (best-effort URL from the
    /// API subject), with a hover-revealed mark-as-read action in HoverRow's trailing slot
    /// while it's unread — the same accessory pattern the PR rows use.
    private func notificationRow(_ notification: GitHubNotification) -> some View {
        HoverRow(trailingAccessory: {
            if notification.unread {
                Button {
                    Task { await store.markRead(notification) }
                } label: {
                    Image(systemName: "checkmark")
                }
                .buttonStyle(GBButtonStyle(variant: .icon))
                .gbTooltip("Mark as read")
                .accessibilityLabel("Mark as read")
            }
        }, content: {
            Button {
                if let url = notification.htmlURL(apiBaseURL: store.apiBaseURL) { openURL(url) }
            } label: {
                NotificationRow(model: NotificationRow.Model(notification))
            }
            .buttonStyle(.plain)
        })
    }

    private var footer: some View {
        HStack {
            Button("Settings…") { openSettingsWindow() }
                .buttonStyle(GBButtonStyle(variant: .ghost))
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(GBButtonStyle(variant: .ghost))
        }
        // Sit the ghost buttons closer to the edges so their rounding echoes the popover corner.
        .padding(.horizontal, Theme.Spacing.sm)
        .padding(.vertical, Theme.Spacing.sm)
    }
}

/// A PR list row: the tappable open-in-browser row plus, when CI has been hydrated,
/// a leading disclosure that expands the per-check `CheckRow` detail. The disclosure is
/// a sibling of the open-URL button (not nested), so toggling it never opens the PR.
private struct PRRowItem: View {
    let store: AppStore
    let item: SearchIssue
    let checks: PRChecks?
    var openURL: (URL) -> Void

    @State private var expanded = false

    /// Leading gutter reserved for the disclosure chevron so PR titles align whether or
    /// not a row has checks to expand.
    private let gutter: CGFloat = Theme.Spacing.lg

    private var checkModels: [CheckRow.Model] {
        checks?.checks ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                disclosure
                // The open-URL button and the quick-action buttons are siblings inside HoverRow
                // (not nested), so tapping Approve/Merge doesn't also fire the row's open-URL
                // action. The accessory only takes hits while revealed (see HoverRow).
                HoverRow(trailingAccessory: {
                    PRQuickActions(store: store, item: item)
                }, content: {
                    Button {
                        if let url = URL(string: item.htmlURL) { openURL(url) }
                    } label: {
                        PRRow(issue: item, ci: checks?.status)
                    }
                    .buttonStyle(.plain)
                })
            }
            if expanded {
                ForEach(checkModels) { model in
                    HoverRow { CheckRow(model: model) }
                        .padding(.leading, gutter)
                }
            }
        }
    }

    @ViewBuilder
    private var disclosure: some View {
        if !checkModels.isEmpty {
            Button {
                withAnimation(Motion.spring) { expanded.toggle() }
            } label: {
                Image(systemName: "chevron.right")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: gutter)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(expanded ? "Hide checks" : "Show checks")
        } else {
            Color.clear.frame(width: gutter, height: 1)
        }
    }
}

/// Shown when no credential is configured yet — reuses the empty-state look with an
/// action that opens Settings.
private struct SignInPromptView: View {
    var openSettings: () -> Void

    var body: some View {
        EmptyStateView(
            intent: .neutral,
            title: "Connect a GitHub account",
            message: "Sign in with GitHub (device flow) or paste a token to get started.",
            actionTitle: "Open Settings…",
            action: openSettings
        )
    }
}

/// Hover-revealed quick actions for a PR row: one-tap Approve (checkmark), and a Merge that
/// opens a confirmation dialog to pick the strategy (merge is irreversible, so it never fires
/// on a single click). Icon-only with tooltips; sits in HoverRow's in-flow accessory slot.
private struct PRQuickActions: View {
    let store: AppStore
    let item: SearchIssue

    @State private var isConfirmingMerge = false
    /// Guards against duplicate submits from a rapid double-tap: while a request is in flight
    /// both buttons are disabled, so a second tap can't queue another approve/merge.
    @State private var isSubmitting = false

    private var prLabel: String {
        "\(item.repositorySlug) #\(item.number)"
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Button { submit { await store.approve(item) } } label: {
                Image(systemName: "checkmark")
            }
            .buttonStyle(GBButtonStyle(variant: .secondary))
            .gbTooltip("Approve")
            .accessibilityLabel("Approve \(prLabel)")

            Button { isConfirmingMerge = true } label: {
                Image(systemName: "arrow.triangle.merge")
            }
            .buttonStyle(GBButtonStyle(variant: .primary))
            .gbTooltip("Merge")
            .accessibilityLabel("Merge \(prLabel)")
        }
        .disabled(isSubmitting)
        .confirmationDialog(
            "Merge \(prLabel)?",
            isPresented: $isConfirmingMerge,
            titleVisibility: .visible
        ) {
            Button("Merge commit") { submit { await store.merge(item, method: .merge) } }
                .accessibilityLabel("Merge commit \(prLabel)")
            Button("Squash and merge") { submit { await store.merge(item, method: .squash) } }
                .accessibilityLabel("Squash and merge \(prLabel)")
            Button("Rebase and merge") { submit { await store.merge(item, method: .rebase) } }
                .accessibilityLabel("Rebase and merge \(prLabel)")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can't be undone.")
        }
    }

    /// Run a quick action guarded by `isSubmitting` so a double-tap can't fire it twice.
    /// `@MainActor`-clean: the flag is only ever read/written on the main actor.
    private func submit(_ action: @escaping () async -> Void) {
        guard !isSubmitting else { return }
        isSubmitting = true
        Task {
            await action()
            isSubmitting = false
        }
    }
}

#if DEBUG
#Preview("Menu — signed out") {
    MenuContentView(store: AppStore())
}
#endif
