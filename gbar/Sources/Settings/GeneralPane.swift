import SwiftUI

/// The General settings pane: background refresh cadence, native-notification preferences, and
/// an About footer. Each section's rows sit inside one grouped card (quiet fill + hairline
/// dividers), so the pane reads as three calm blocks instead of a loose stack of controls.
struct GeneralPane: View {
    @Bindable var store: AppStore
    @Environment(\.openURL) private var openURL

    private static let repoURL = URL(string: "https://github.com/jaylann/gbar")

    /// Deep link straight to gbar's row in System Settings → Notifications.
    private static let notificationSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=dev.lanfermann.gbar"
    )

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                refreshSection
                notificationsSection
                aboutSection
                footer
            }
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, Theme.Spacing.md)
        }
        .task { await store.refreshNotificationAuthStatus() }
        // Re-check when gbar regains focus, so flipping the toggle in System Settings and
        // clicking back updates the row without reopening the pane.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await store.refreshNotificationAuthStatus() }
        }
    }

    // MARK: Refresh

    private var refreshSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            SectionHeader(title: "Refresh")
            groupCard {
                settingRow(
                    title: "Auto-refresh",
                    subtitle: "How often gbar checks GitHub while the menu is closed."
                ) {
                    Menu {
                        ForEach(PollInterval.allCases) { option in
                            Button {
                                store.pollInterval = option.rawValue
                            } label: {
                                if option == currentInterval {
                                    Label(option.label, systemImage: "checkmark")
                                } else {
                                    Text(option.label)
                                }
                            }
                        }
                    } label: {
                        Text(currentInterval.label)
                    }
                    .menuStyle(.button)
                    .buttonStyle(GBButtonStyle(variant: .secondary))
                    .fixedSize()
                }
            }
        }
    }

    private var currentInterval: PollInterval {
        PollInterval(rawValue: store.pollInterval) ?? .m1
    }

    // MARK: Notifications

    private var notificationsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            SectionHeader(title: "Notifications")
            Text("Native banners for new items and CI pass/fail on your PRs. Click one to open it in the browser.")
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.bottom, Theme.Spacing.xs)
            groupCard {
                toggleRow("Enable notifications", isOn: $store.notificationsEnabled)
                Divider()
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    toggleRow("New notifications", isOn: $store.notifyInbox)
                    toggleRow("New PRs & issues", isOn: $store.notifySections)
                    toggleRow("CI status changes", isOn: $store.notifyChecks)
                }
                .padding(.leading, Theme.Spacing.md)
                .disabled(!store.notificationsEnabled)
                .opacity(store.notificationsEnabled ? 1 : 0.5)
                Divider()
                authStatusRow
            }
            .toggleStyle(.switch)
            .tint(Theme.Palette.accent)
            .font(Theme.Typography.rowTitle.weight(.regular))
        }
    }

    /// OS-authorization surface: a warning + System Settings deep link when banners are blocked,
    /// a permission prompt when never asked, and a test-banner button to verify delivery.
    @ViewBuilder private var authStatusRow: some View {
        if store.notificationsEnabled, store.notificationAuthStatus == .denied {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Label(
                    "Notifications are off for gbar in System Settings, so banners won't appear.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)
                .tint(Theme.Palette.pending)
                .fixedSize(horizontal: false, vertical: true)
                Button {
                    if let url = Self.notificationSettingsURL { openURL(url) }
                } label: {
                    Label("Open System Settings", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(GBButtonStyle(variant: .secondary))
            }
        } else if store.notificationsEnabled, store.notificationAuthStatus == .notDetermined {
            Button {
                Task { await store.requestNotificationAuthorization() }
            } label: {
                Label("Request permission", systemImage: "bell.badge")
            }
            .buttonStyle(GBButtonStyle(variant: .secondary))
        } else {
            Button {
                store.sendTestNotification()
            } label: {
                Label("Send test notification", systemImage: "bell.badge")
            }
            .buttonStyle(GBButtonStyle(variant: .ghost))
            .disabled(!store.notificationsEnabled)
        }
    }

    // MARK: About

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            SectionHeader(title: "About")
            groupCard {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.md) {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        HStack(spacing: Theme.Spacing.xs) {
                            Text("gbar")
                                .font(Theme.Typography.rowTitle)
                                .foregroundStyle(Theme.Palette.accent)
                            Text("v\(appVersion)")
                                .font(Theme.Typography.mono)
                                .foregroundStyle(.secondary)
                        }
                        Text("A GitHub companion for the macOS menu bar.")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(.secondary)
                        Text("Source-available under PolyForm Shield 1.0.0.")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                    if let url = Self.repoURL {
                        Button {
                            openURL(url)
                        } label: {
                            Label("View on GitHub", systemImage: "arrow.up.right.square")
                        }
                        .buttonStyle(GBButtonStyle(variant: .ghost))
                    }
                }
            }
        }
    }

    /// Quiet maker's mark at the very bottom of Settings.
    private var footer: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Text("Made by")
            Button("Justin Lanfermann") {
                if let url = URL(string: "https://lanfermann.dev") { openURL(url) }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .underline()
            .gbTooltip("lanfermann.dev")
        }
        .font(Theme.Typography.caption)
        .foregroundStyle(.tertiary)
        .frame(maxWidth: .infinity)
        .padding(.top, Theme.Spacing.xs)
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    // MARK: Layout helpers

    /// One grouped settings card: the section's rows on a quiet fill with rounded corners,
    /// separated by explicit `Divider()`s at the call site.
    private func groupCard(@ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            content()
        }
        .padding(Theme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Surface.controlFill, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        .padding(.horizontal, Theme.Spacing.md)
    }

    /// A switch row with the label leading and the switch pinned to the card's trailing edge,
    /// so every switch in a card lines up in one column.
    private func toggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
        settingRow(title: title) {
            Toggle(title, isOn: isOn)
                .labelsHidden()
        }
    }

    /// A labeled settings row: a title (+ optional explanatory subtitle) on the left, a trailing
    /// control on the right.
    private func settingRow(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder control: () -> some View
    )
    -> some View {
        HStack(alignment: .center, spacing: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.Typography.rowTitle.weight(.regular))
                if let subtitle {
                    Text(subtitle)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            control()
        }
    }
}

#if DEBUG
#Preview("GeneralPane") {
    GeneralPane(store: AppStore())
        .frame(width: Theme.Layout.settingsWidth, height: Theme.Layout.settingsHeight)
        .background(Surface.canvas)
}
#endif
