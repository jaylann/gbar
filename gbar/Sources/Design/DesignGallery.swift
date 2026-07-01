#if DEBUG
import SwiftUI

/// A single canvas showing the whole design system at once. Preview-only — never
/// shipped. Open this file in Xcode and resume the canvas to scan every component and
/// state side by side in light and dark. Individual components also have their own
/// focused `#Preview` blocks.
struct DesignGallery: View {
    @State private var domain = "prs"
    @State private var filterOpen = true
    @State private var filterDraft = false
    @State private var filterFailing = false
    @State private var search = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                group("Navigation") {
                    GBSegmentedControl(
                        segments: [
                            .init(tag: "prs", title: "PRs", symbol: "arrow.triangle.pull", count: 4),
                            .init(tag: "issues", title: "Issues", symbol: "smallcircle.filled.circle"),
                            .init(tag: "checks", title: "Checks", symbol: "checkmark.seal"),
                            .init(tag: "inbox", title: "Inbox", symbol: "bell", count: 2),
                        ],
                        selection: $domain
                    )
                    HStack(spacing: Theme.Spacing.sm) {
                        FilterChip(title: "Open", symbol: "smallcircle.filled.circle", isOn: $filterOpen)
                        FilterChip(title: "Draft", isOn: $filterDraft)
                        FilterChip(title: "Failing", symbol: "xmark.circle", isOn: $filterFailing)
                    }
                    SearchField(placeholder: "Filter PRs", text: $search)
                }

                group("State badges") {
                    HStack(spacing: Theme.Spacing.sm) {
                        StateBadge(state: .open)
                        StateBadge(state: .draft)
                        StateBadge(state: .merged)
                        StateBadge(state: .closed)
                        StateBadge(state: .done)
                    }
                }

                group("CI status") {
                    HStack(spacing: Theme.Spacing.lg) {
                        ForEach([CIStatus.success, .failure, .pending, .neutral, .error], id: \.label) { status in
                            VStack(spacing: Theme.Spacing.xs) {
                                CIStatusIndicator(status: status)
                                Text(status.label).font(Theme.Typography.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                group("Buttons") {
                    HStack(spacing: Theme.Spacing.sm) {
                        Button("Merge") {}.buttonStyle(GBButtonStyle(variant: .primary))
                        Button("Approve") {}.buttonStyle(GBButtonStyle(variant: .secondary))
                        Button("Dismiss") {}.buttonStyle(GBButtonStyle(variant: .ghost))
                        Button {} label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(GBButtonStyle(variant: .icon))
                        Button("Merging") {}.buttonStyle(GBButtonStyle(variant: .primary, isLoading: true))
                    }
                }

                group("Avatars, badges, diff") {
                    HStack(spacing: Theme.Spacing.lg) {
                        Avatar(login: "jaylann", size: .small)
                        Avatar(login: "octocat", size: .medium)
                        Avatar(login: "github", size: .large)
                        CountBadge(3)
                        CountBadge(12, emphasized: true)
                        DiffStat(additions: 42, deletions: 7)
                        UnseenDot(isUnseen: true)
                    }
                }

                group("PR rows") {
                    rowStack {
                        HoverRow { PRRow(
                            issue: .previewOpenPR,
                            ci: .success,
                            additions: 42,
                            deletions: 7,
                            isUnseen: true
                        )
                        }
                        HoverRow { PRRow(issue: .previewDraftPR, ci: .pending) }
                        HoverRow(isFocused: true) { PRRow(issue: .previewMergedPR, additions: 3, deletions: 0) }
                    }
                }

                group("Issue rows") {
                    rowStack {
                        HoverRow { IssueRow(issue: .previewOpenIssue, labels: ["bug", "ui"], isUnseen: true) }
                        HoverRow { IssueRow(issue: .previewClosedIssue) }
                    }
                }

                group("Notification rows") {
                    rowStack {
                        HoverRow {
                            NotificationRow(model: .init(
                                id: "1",
                                repo: "jaylann/gbar",
                                title: "Add device-flow token refresh",
                                reason: .reviewRequested,
                                date: Date(timeIntervalSinceNow: -900),
                                isUnread: true,
                                symbol: "arrow.triangle.pull"
                            ))
                        }
                        HoverRow {
                            NotificationRow(model: .init(
                                id: "2",
                                repo: "jaylann/gbar",
                                title: "Popover flickers on first open",
                                reason: .mention,
                                date: Date(timeIntervalSinceNow: -14400),
                                isUnread: false,
                                symbol: "smallcircle.filled.circle"
                            ))
                        }
                    }
                }

                group("Check rows") {
                    rowStack {
                        HoverRow {
                            CheckRow(model: .init(
                                id: "1",
                                repo: "jaylann/gbar",
                                branch: "feature/design-system",
                                workflow: "CI / build-and-test",
                                status: .success,
                                duration: "1m 42s"
                            ))
                        }
                        HoverRow {
                            CheckRow(model: .init(
                                id: "2",
                                repo: "jaylann/gbar",
                                branch: "stage",
                                workflow: "CI / lint",
                                status: .pending,
                                duration: nil
                            ))
                        }
                    }
                }

                group("Feedback states") {
                    VStack(spacing: Theme.Spacing.md) {
                        EmptyStateView(
                            intent: .caughtUp,
                            title: "You're all caught up",
                            message: "No reviews need you right now."
                        )
                        LoadingView()
                        ErrorStateView(kind: .rateLimited(resetsIn: "12m")) {}
                    }
                }
            }
            .padding(Theme.Spacing.lg)
        }
        .frame(width: 420, height: 900)
    }

    private func group(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text(title.uppercased())
                .font(Theme.Typography.sectionLabel)
                .foregroundStyle(.tertiary)
                .kerning(0.4)
            content()
        }
    }

    private func rowStack(@ViewBuilder content: () -> some View) -> some View {
        VStack(spacing: 2, content: content)
            .background(
                Color(nsColor: .textBackgroundColor).opacity(0.4),
                in: RoundedRectangle(cornerRadius: Theme.Radius.md)
            )
    }
}

#Preview("Design gallery — light") {
    DesignGallery().preferredColorScheme(.light)
}

#Preview("Design gallery — dark") {
    DesignGallery().preferredColorScheme(.dark)
}
#endif
