import SwiftUI

/// The MenuBarExtra window, built on the design system: a header with the live badge
/// count, the resolved sections (or a first-load skeleton / caught-up / error state),
/// and a footer. Sign-in prompt when signed out.
struct MenuContentView: View {
    @Bindable var store: AppStore
    @Environment(\.openURL) private var openURL
    @Environment(\.openSettings) private var openSettings

    private var isEmpty: Bool {
        store.sections.allSatisfy(\.items.isEmpty) && store.notifications.isEmpty
    }

    var body: some View {
        PopoverContainer {
            VStack(alignment: .leading, spacing: 0) {
                header
                Divider()
                content
                Divider()
                footer
            }
        }
        // Skip if the background poll loop is already refreshing, so opening the menu doesn't
        // overlap an in-flight fetch (see AppStore.startPolling). Note(#10): refresh() itself
        // has no reentrancy guard, so this is a mitigation, not a hard lock.
        .task { if store.isSignedIn, !store.isRefreshing { await store.refresh() } }
    }

    private var header: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Text("gbar").font(.headline)
            CountBadge(store.badgeCount, emphasized: true)
            Spacer()
            Button {
                Task { await store.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(GBButtonStyle(variant: .icon, isLoading: store.isRefreshing))
            .disabled(store.isRefreshing || !store.isSignedIn)
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.sm)
    }

    /// Just open the Settings scene. The activation dance an `LSUIElement` agent app
    /// needs to make that window take keyboard focus — and the demotion back to a
    /// no-Dock-icon agent on close — is owned entirely by `WindowActivator` inside
    /// `SettingsView`, so it applies however Settings is opened (this button, the
    /// sign-in prompt, or the system ⌘, shortcut).
    private func openSettingsWindow() {
        openSettings()
    }

    @ViewBuilder
    private var content: some View {
        if !store.isSignedIn {
            SignInPromptView { openSettingsWindow() }
        } else if !isEmpty {
            // Always render loaded data. A per-section failure sets `lastErrorMessage`
            // while still populating the sections that succeeded, so a partial error
            // must not blank the list — surface it as a quiet banner above it instead.
            VStack(alignment: .leading, spacing: 0) {
                if let message = store.lastErrorMessage {
                    errorBanner(message)
                }
                sectionsList
            }
        } else if !store.hasLoaded {
            LoadingView().padding(.vertical, Theme.Spacing.sm)
        } else if store.sessionExpired {
            ErrorStateView(kind: .authExpired, retryTitle: "Open Settings") { openSettingsWindow() }
        } else if let message = store.lastErrorMessage {
            ErrorStateView(kind: .generic) { Task { await store.refresh() } }
                .help(message)
        } else {
            EmptyStateView(intent: .caughtUp, title: "You're all caught up", message: "Nothing needs you right now.")
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

    private var sectionsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                ForEach(store.sections) { section in
                    if !section.items.isEmpty {
                        Section {
                            ForEach(section.items) { item in
                                row(item)
                            }
                        } header: {
                            SectionHeader(title: section.title, count: section.items.count)
                        }
                    }
                }
                if !store.notifications.isEmpty {
                    Section {
                        ForEach(store.notifications) { notification in
                            notificationRow(notification)
                        }
                    } header: {
                        SectionHeader(title: "Notifications", count: store.notifications.count)
                    }
                }
            }
            .padding(.vertical, Theme.Spacing.xs)
        }
    }

    /// A notification row: tap the body to open it in the browser (best-effort URL from the
    /// API subject), with a trailing mark-as-read action shown while it's unread. HoverRow has
    /// no trailing-accessory slot yet, so the action lives inside the row content.
    private func notificationRow(_ notification: GitHubNotification) -> some View {
        HoverRow {
            HStack(spacing: Theme.Spacing.xs) {
                Button {
                    if let url = notification.htmlURL(apiBaseURL: store.apiBaseURL) { openURL(url) }
                } label: {
                    NotificationRow(model: NotificationRow.Model(notification))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)

                if notification.unread {
                    Button {
                        Task { await store.markRead(notification) }
                    } label: {
                        Image(systemName: "checkmark")
                    }
                    .buttonStyle(GBButtonStyle(variant: .icon))
                    .help("Mark as read")
                    .accessibilityLabel("Mark as read")
                }
            }
        }
    }

    private func row(_ item: SearchIssue) -> some View {
        // The open-URL button and the quick-action buttons are siblings inside HoverRow (not
        // nested), so tapping Approve/Merge doesn't also fire the row's open-URL action. The
        // accessory only takes hits while revealed (see HoverRow.allowsHitTesting).
        HoverRow(trailingAccessory: {
            // PR-only: issues keep their plain row.
            if item.isPullRequest {
                PRQuickActions(store: store, item: item)
            }
        }, content: {
            Button {
                if let url = URL(string: item.htmlURL) { openURL(url) }
            } label: {
                if item.isPullRequest {
                    PRRow(issue: item)
                } else {
                    IssueRow(issue: item)
                }
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
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.sm)
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

/// Hover-revealed quick actions for a PR row: one-tap Approve, and a Merge that opens a
/// confirmation dialog to pick the strategy (merge is irreversible, so it never fires on a
/// single click). Sits on an opaque chip so it cleanly covers the row content it overlays.
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
            Button("Approve") { submit { await store.approve(item) } }
                .buttonStyle(GBButtonStyle(variant: .secondary))
                .accessibilityLabel("Approve \(prLabel)")

            Button("Merge") { isConfirmingMerge = true }
                .buttonStyle(GBButtonStyle(variant: .primary))
                .accessibilityLabel("Merge \(prLabel)")
        }
        .disabled(isSubmitting)
        .padding(.horizontal, Theme.Spacing.xs)
        .background(Surface.canvas, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
        // Consume taps across the whole chip so clicks in the spacing/padding gaps don't fall
        // through to the underlying full-width open-URL button and open the PR.
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
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
