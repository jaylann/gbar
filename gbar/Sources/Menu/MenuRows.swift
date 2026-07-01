import SwiftUI

/// A PR list row: the tappable open-in-browser row plus, when CI has been hydrated,
/// a leading disclosure that expands the per-check `CheckRow` detail. The disclosure is
/// a sibling of the open-URL button (not nested), so toggling it never opens the PR.
struct PRRowItem: View {
    let store: AppStore
    let item: AccountItem
    let checks: PRChecks?
    var openURL: (URL) -> Void

    @State private var expanded = false
    @State private var isConfirmingMerge = false
    /// Guards against duplicate submits from a rapid double-tap. Owned here (not in the
    /// hover-gated `PRQuickActions`) so it survives the accessory unmounting on hover-out.
    @State private var isSubmitting = false

    /// Leading gutter reserved for the disclosure chevron so PR titles align whether or
    /// not a row has checks to expand.
    private let gutter: CGFloat = Theme.Spacing.lg

    private var issue: SearchIssue {
        item.issue
    }

    private var checkModels: [CheckRow.Model] {
        checks?.checks ?? []
    }

    private var prLabel: String {
        "\(issue.repositorySlug) #\(issue.number)"
    }

    /// Own PRs can't be approved (GitHub 422s) — detectable instantly without hydration.
    private var isOwnPR: Bool {
        issue.user?.login.lowercased() == item.account.login.lowercased()
    }

    /// Show Approve unless it's the viewer's own PR or they've already approved it. Until the
    /// gate hydrates, only the (synchronous) own-PR check applies — stay optimistic otherwise.
    private var showApprove: Bool {
        !isOwnPR && !(store.gate(for: item)?.alreadyApproved ?? false)
    }

    /// Show Merge unless the gate says the PR isn't actually mergeable. Optimistic (shown)
    /// until hydration resolves the gate.
    private var showMerge: Bool {
        store.gate(for: item)?.mergeable ?? true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                disclosure
                // The open-URL button and the quick-action buttons are siblings inside HoverRow
                // (not nested), so tapping Approve/Merge doesn't also fire the row's open-URL
                // action. The accessory only takes hits while revealed (see HoverRow).
                HoverRow(trailingAccessory: {
                    PRQuickActions(
                        issue: issue,
                        isSubmitting: isSubmitting,
                        showApprove: showApprove,
                        showMerge: showMerge,
                        onApprove: { submit { await store.approve(item) } },
                        onMerge: { isConfirmingMerge = true }
                    )
                }, content: {
                    Button {
                        if let url = URL(string: issue.htmlURL) { openURL(url) }
                    } label: {
                        PRRow(issue: issue, ci: checks?.status)
                    }
                    .buttonStyle(.plain)
                    // Keep the hover-gated Approve/Merge reachable via VoiceOver's actions rotor —
                    // but only the ones actually applicable to this PR.
                    .accessibilityActions {
                        if showApprove {
                            Button("Approve \(prLabel)") { submit { await store.approve(item) } }
                        }
                        if showMerge {
                            Button("Merge \(prLabel)") { isConfirmingMerge = true }
                        }
                    }
                })
            }
            if expanded {
                ForEach(checkModels) { model in
                    HoverRow { CheckRow(model: model) }
                        .padding(.leading, gutter)
                }
            }
        }
        // The dialog lives on the always-mounted row, not on the hover-gated accessory, so
        // moving the pointer to the dialog (which drops row hover) can't dismiss it mid-choice.
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

/// Hover-revealed quick actions for a PR row: one-tap Approve (checkmark) and Merge (which
/// asks the owning row to open the strategy dialog — merge is irreversible, so it never fires
/// on a single click). Stateless: the submit guard and the dialog live on `PRRowItem` so they
/// survive this view unmounting when hover ends.
private struct PRQuickActions: View {
    let issue: SearchIssue
    let isSubmitting: Bool
    /// Whether each action applies to this PR — a button is omitted entirely when false, so
    /// the viewer only ever sees actions that would actually succeed.
    let showApprove: Bool
    let showMerge: Bool
    var onApprove: () -> Void
    var onMerge: () -> Void

    private var prLabel: String {
        "\(issue.repositorySlug) #\(issue.number)"
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            if showApprove {
                Button { onApprove() } label: {
                    Image(systemName: "checkmark")
                }
                .buttonStyle(GBButtonStyle(variant: .secondary))
                .gbTooltip("Approve")
                .accessibilityLabel("Approve \(prLabel)")
            }

            if showMerge {
                Button { onMerge() } label: {
                    Image(systemName: "arrow.triangle.merge")
                }
                .buttonStyle(GBButtonStyle(variant: .primary))
                .gbTooltip("Merge")
                .accessibilityLabel("Merge \(prLabel)")
            }
        }
        .disabled(isSubmitting)
    }
}

/// Shown when no account is connected yet — reuses the empty-state look with an action
/// that opens Settings.
struct SignInPromptView: View {
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
