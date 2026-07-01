import SwiftUI

/// The General settings pane: background refresh cadence, native-notification preferences, and
/// an About footer with the build version and the source-available license line.
struct GeneralPane: View {
    @Bindable var store: AppStore
    @Environment(\.openURL) private var openURL

    private static let repoURL = URL(string: "https://github.com/jaylann/gbar")

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                refreshSection
                notificationsSection
                aboutSection
            }
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, Theme.Spacing.md)
        }
    }

    // MARK: Refresh

    private var refreshSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            SectionHeader(title: "Refresh")
            settingRow(
                title: "Auto-refresh",
                subtitle: "How often gbar checks GitHub while the menu is closed — keeps the badge current."
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

    private var currentInterval: PollInterval {
        PollInterval(rawValue: store.pollInterval) ?? .m1
    }

    // MARK: Notifications

    private var notificationsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            SectionHeader(title: "Notifications")
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Toggle("Enable notifications", isOn: $store.notificationsEnabled)
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    Toggle("New notifications", isOn: $store.notifyInbox)
                    Toggle("New PRs & issues", isOn: $store.notifySections)
                    Toggle("CI status changes", isOn: $store.notifyChecks)
                }
                .padding(.leading, Theme.Spacing.md)
                .disabled(!store.notificationsEnabled)
                Text("Native banners for new items and CI pass/fail on your PRs. Click one to open it in the browser.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)
            }
            .toggleStyle(.switch)
            .tint(Theme.Palette.accent)
            .font(Theme.Typography.rowTitle.weight(.regular))
            .padding(.horizontal, Theme.Spacing.md)
        }
    }

    // MARK: About

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            SectionHeader(title: "About")
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
                if let url = Self.repoURL {
                    Button {
                        openURL(url)
                    } label: {
                        Label("View on GitHub", systemImage: "arrow.up.right.square")
                    }
                    .buttonStyle(GBButtonStyle(variant: .ghost))
                    .padding(.top, Theme.Spacing.xs)
                }
            }
            .padding(.horizontal, Theme.Spacing.md)
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    // MARK: Layout helper

    /// A labeled settings row: a title (+ optional explanatory subtitle) on the left, a trailing
    /// control on the right, aligned to the pane's text inset.
    private func settingRow(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder control: () -> some View
    )
    -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
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
        .padding(.horizontal, Theme.Spacing.md)
    }
}

#if DEBUG
#Preview("GeneralPane") {
    GeneralPane(store: AppStore())
        .frame(width: 500, height: 560)
        .background(Surface.canvas)
}
#endif
