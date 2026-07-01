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

/// The status-item popover, built on the design system: a consolidated top bar — inline
/// `PRs | Issues | Inbox` tabs on the left, a search toggle, refresh, and a Settings gear on
/// the right — with a search field that slides in on demand and PR filter chips on the PRs tab.
/// Below it, the active tab's sections (or its own first-load skeleton / caught-up / error
/// state). Sign-in prompt when signed out.
struct MenuContentView: View {
    @Bindable var store: AppStore
    /// Opens the Settings scene. Injected by `StatusItemController` because this view is hosted
    /// in an `NSPopover` (outside the SwiftUI scene graph), where `\.openSettings` isn't wired.
    let openSettings: () -> Void
    @Environment(\.openURL) private var openURL
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
                    // Search/filters only make sense over a loaded, filterable list — keep them
                    // off the loading skeleton, the auth-expired prompt, and the empty store.
                    if showsFilters, searchActive {
                        searchRow
                    }
                    if showsFilters, selectedTab == .prs {
                        chipsRow
                    }
                    Divider()
                    tabContent
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    SignInPromptView { openSettingsWindow() }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            // Give the signed-in popover a comfortable minimum body so a short list still opens
            // tall; the sign-in prompt sizes to its content (`maxHeight` on the container caps both).
            .frame(minHeight: store.isSignedIn ? 560 : nil)
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
            // Nudge the action icons up so their centers meet the tab labels: the tab bar
            // reserves a 2pt underline anchor below its labels, sitting lower than these
            // fixed-height icon buttons would otherwise center to.
            HStack(spacing: Theme.Spacing.sm) {
                if store.accounts.count > 1 {
                    accountFilterMenu
                }
                Button { toggleSearch() } label: {
                    Image(systemName: searchActive ? "xmark" : "magnifyingglass")
                }
                .buttonStyle(GBButtonStyle(variant: .icon))
                .disabled(!showsFilters)
                .gbTooltip(searchActive ? "Close search" : "Search", edge: .bottom)
                Button {
                    Task { await store.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(GBButtonStyle(variant: .icon, isLoading: store.isRefreshing))
                .disabled(store.isRefreshing || !store.isSignedIn)
                .gbTooltip("Refresh", edge: .bottom)
                Button { openSettingsWindow() } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(GBButtonStyle(variant: .icon))
                .gbTooltip("Settings", edge: .bottom)
            }
            .offset(y: -3)
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.sm)
    }

    /// Header control that scopes every tab to All accounts or one account. Client-side over
    /// already-fetched data, so switching is instant (no refetch). Only shown with >1 account.
    private var accountFilterMenu: some View {
        Menu {
            Button { store.accountFilter = nil } label: {
                Label("All accounts", systemImage: store.accountFilter == nil ? "checkmark" : "person.2")
            }
            Divider()
            ForEach(store.accounts) { account in
                Button { store.accountFilter = account.id } label: {
                    if store.accountFilter == account.id {
                        Label(account.login, systemImage: "checkmark")
                    } else {
                        Text(account.login)
                    }
                }
            }
        } label: {
            if let filter = store.accountFilter,
               let account = store.accounts.first(where: { $0.id == filter })
            {
                Avatar(login: account.login, url: account.avatarImageURL, size: .small)
            } else {
                Image(systemName: "person.2")
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .gbTooltip("Filter by account", edge: .bottom)
        .accessibilityLabel("Filter by account")
    }

    /// Show a per-row account avatar only when results span multiple accounts and none is
    /// selected — so provenance is clear in the merged view, but not redundant when scoped.
    private var showsAccountBadges: Bool {
        store.accountFilter == nil && store.accounts.count > 1
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
        if !store.hasLoaded {
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

    /// The whole (account-filtered) store has no loaded results — used to decide whether an
    /// error/auth-expired state should take over the tab (only when there's nothing to keep on
    /// screen). Uses the filtered projections so scoping to an empty account still reads as
    /// caught-up rather than an error.
    private var storeIsEmpty: Bool {
        (store.prSections + store.issueSections).allSatisfy(\.items.isEmpty)
            && store.visibleNotifications.isEmpty
    }

    /// Show the search field and PR filter chips only when there's a loaded, filterable list —
    /// not during first load, an expired session, or an empty store.
    private var showsFilters: Bool {
        store.hasLoaded && !store.sessionExpired && !storeIsEmpty
    }

    private var prList: some View {
        let groups = filteredSections(store.prSections) { matchesSearch($0.item.issue) && prPredicate($0) }
        return tabScaffold(isEmpty: groups.isEmpty) {
            emptyState(caughtUpTitle: "No pull requests", caughtUpMessage: "Nothing needs you right now.")
        } content: {
            ForEach(groups, id: \.section.id) { group in
                Section {
                    ForEach(group.items) { item in
                        row(item)
                    }
                } header: {
                    SectionHeader(title: group.section.title, count: group.items.count)
                }
            }
        }
    }

    private var issueList: some View {
        let groups = filteredSections(store.issueSections) { matchesSearch($0.item.issue) }
        return tabScaffold(isEmpty: groups.isEmpty) {
            emptyState(caughtUpTitle: "No issues", caughtUpMessage: "No issues assigned to you.")
        } content: {
            ForEach(groups, id: \.section.id) { group in
                Section {
                    ForEach(group.items) { item in
                        row(item)
                    }
                } header: {
                    SectionHeader(title: group.section.title, count: group.items.count)
                }
            }
        }
    }

    private var notificationList: some View {
        let items = store.visibleNotifications.filter { matchesSearch($0.notification) }
        return tabScaffold(isEmpty: items.isEmpty) {
            emptyState(caughtUpTitle: "Inbox zero", caughtUpMessage: "Nothing unread right now.")
        } content: {
            ForEach(items) { notification in
                notificationRow(notification)
            }
        }
    }

    /// The shared per-tab frame. When the tab has rows, show them under a quiet error banner
    /// (a partial failure — or an expired session while data is still on screen — must never
    /// blank a populated tab). A full-screen auth/error state takes over only when the whole
    /// store is empty, so an unrelated tab's failure can't mask this tab's caught-up state.
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
        } else if storeIsEmpty, store.sessionExpired {
            reconnectState
        } else if storeIsEmpty, let message = store.lastErrorMessage {
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
}

/// Filtering predicates and row builders, split into an extension to keep the primary view
/// body within the type-length limit.
extension MenuContentView {
    // MARK: Reconnect (per-account 401 recovery)

    /// The session-expired takeover. When the expired account can reconnect in place (OAuth + a
    /// known client ID), offer a one-click device-flow "Reconnect <login>" that re-auths without
    /// leaving the popover; otherwise (a PAT, or no stored client ID) fall back to opening
    /// Settings. `reauthStatus` drives the intermediate states (user code, failure retry).
    @ViewBuilder
    private var reconnectState: some View {
        switch store.reauthStatus {
        case .idle:
            if store.canReconnect, let login = store.expiredAccount?.login {
                ErrorStateView(kind: .authExpired, retryTitle: "Reconnect \(login)") { reconnect() }
            } else {
                ErrorStateView(kind: .authExpired, retryTitle: "Open Settings") { openSettingsWindow() }
            }
        case .starting:
            ErrorStateView(kind: .authExpired, messageOverride: "Starting reconnect…")
        case let .awaitingAuthorization(code):
            ErrorStateView(
                kind: .authExpired,
                messageOverride: "Enter code \(code) in the browser, then approve gbar to reconnect."
            )
        case let .failed(message):
            ErrorStateView(kind: .authExpired, messageOverride: message, retryTitle: "Try again") { reconnect() }
        }
    }

    /// Kick off an in-place device-flow reconnect for the expired account, opening the
    /// verification URL via the environment's `openURL` (the store stays UI-framework-light and
    /// just hands back the URL).
    private func reconnect() {
        Task { await store.reconnect { url in openURL(url) } }
    }

    // MARK: Filtering

    /// Apply a per-item predicate to each section and drop the sections left empty, keeping the
    /// remaining sections intact (routing decision: sections are never split across tabs).
    private func filteredSections(
        _ sections: [LoadedSection],
        matching predicate: ((section: LoadedSection, item: AccountItem)) -> Bool
    )
    -> [(section: LoadedSection, items: [AccountItem])] {
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

    private func prPredicate(_ entry: (section: LoadedSection, item: AccountItem)) -> Bool {
        switch prFilter {
        case .all: true
        case .failingCI: store.checks(for: entry.item)?.status == .failure
        case .needsReview: entry.section.id == "review-requested"
        }
    }

    // MARK: Rows

    /// A small leading account avatar shown only in the merged multi-account view, so a row's
    /// provenance is clear. Collapses to nothing when scoped to a single account.
    @ViewBuilder
    private func accountBadge(_ item: AccountItem) -> some View {
        if showsAccountBadges {
            Avatar(login: item.account.login, url: item.account.avatarImageURL, size: .small)
                .gbTooltip(item.account.login)
        }
    }

    /// Route by the item itself, not just its section: a section can contain both PRs and
    /// issues (e.g. a query without `is:pr`/`is:issue`), so PRs always get the CI disclosure +
    /// Approve/Merge and issues stay read-only — whichever tab the section is routed to.
    private func row(_ item: AccountItem) -> some View {
        HStack(spacing: Theme.Spacing.xs) {
            accountBadge(item)
            if item.issue.isPullRequest {
                PRRowItem(store: store, item: item, checks: store.checks(for: item)) { url in openURL(url) }
            } else {
                issueRow(item)
            }
        }
    }

    private func issueRow(_ item: AccountItem) -> some View {
        Button {
            if let url = URL(string: item.issue.htmlURL) { openURL(url) }
        } label: {
            HoverRow { IssueRow(issue: item.issue) }
        }
        .buttonStyle(.plain)
    }

    /// A notification row: tap the body to open it in the browser (best-effort URL from the
    /// API subject), with a hover-revealed mark-as-read action in HoverRow's trailing slot
    /// while it's unread — the same accessory pattern the PR rows use.
    private func notificationRow(_ item: AccountNotification) -> some View {
        let notification = item.notification
        return HStack(spacing: Theme.Spacing.xs) {
            if showsAccountBadges {
                Avatar(login: item.account.login, url: item.account.avatarImageURL, size: .small)
                    .gbTooltip(item.account.login)
            }
            HoverRow(trailingAccessory: {
                if notification.unread {
                    Button {
                        Task { await store.markRead(item) }
                    } label: {
                        Image(systemName: "checkmark")
                    }
                    .buttonStyle(GBButtonStyle(variant: .icon))
                    .gbTooltip("Mark as read")
                    .accessibilityLabel("Mark as read")
                }
            }, content: {
                Button {
                    if let url = notification.htmlURL(apiBaseURL: item.account.apiBaseURL) { openURL(url) }
                } label: {
                    NotificationRow(model: NotificationRow.Model(notification))
                }
                .buttonStyle(.plain)
                // The visible mark-read button is hover-gated; keep the action reachable via
                // VoiceOver's actions rotor on the always-present row body.
                .accessibilityAction(named: "Mark as read") {
                    if notification.unread { Task { await store.markRead(item) } }
                }
            })
        }
    }
}

#if DEBUG
#Preview("Menu — signed out") {
    MenuContentView(store: AppStore()) {}
}
#endif
