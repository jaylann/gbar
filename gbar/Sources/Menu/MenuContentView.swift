import SwiftUI

/// The MenuBarExtra window, built on the design system: a header with the live badge
/// count, the resolved sections (or a first-load skeleton / caught-up / error state),
/// and a footer. Sign-in prompt when signed out.
struct MenuContentView: View {
    @Bindable var store: AppStore
    @Environment(\.openURL) private var openURL
    @Environment(\.openSettings) private var openSettings

    private var isEmpty: Bool {
        store.sections.allSatisfy(\.items.isEmpty)
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
        .task { if store.isSignedIn { await store.refresh() } }
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

    /// Opening a window from an `LSUIElement` agent app is a two-part problem: the app
    /// runs with `.accessory` activation policy, so its windows show but can't become
    /// key — text fields silently swallow no keystrokes. Promote to `.regular` and
    /// activate so the Settings window can take keyboard focus; `SettingsView` drops
    /// back to `.accessory` (no Dock icon) when it closes.
    private func openSettingsWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
    }

    @ViewBuilder
    private var content: some View {
        if !store.isSignedIn {
            SignInPromptView { openSettingsWindow() }
        } else if store.sessionExpired {
            ErrorStateView(kind: .authExpired, retryTitle: "Open Settings") { openSettingsWindow() }
        } else if let message = store.lastErrorMessage {
            ErrorStateView(kind: .generic) { Task { await store.refresh() } }
                .help(message)
        } else if store.isRefreshing, isEmpty {
            LoadingView().padding(.vertical, Theme.Spacing.sm)
        } else if isEmpty {
            EmptyStateView(intent: .caughtUp, title: "You're all caught up", message: "Nothing needs you right now.")
        } else {
            sectionsList
        }
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
            }
            .padding(.vertical, Theme.Spacing.xs)
        }
    }

    private func row(_ item: SearchIssue) -> some View {
        Button {
            if let url = URL(string: item.htmlURL) { openURL(url) }
        } label: {
            HoverRow {
                if item.isPullRequest {
                    PRRow(issue: item)
                } else {
                    IssueRow(issue: item)
                }
            }
        }
        .buttonStyle(.plain)
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

#if DEBUG
#Preview("Menu — signed out") {
    MenuContentView(store: AppStore())
}
#endif
