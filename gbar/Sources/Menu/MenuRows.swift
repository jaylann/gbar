import SwiftUI

/// A PR list row: the tappable open-in-browser row plus, when CI has been hydrated,
/// a leading disclosure that expands the per-check `CheckRow` detail. The disclosure is
/// a sibling of the open-URL button (not nested), so toggling it never opens the PR.
struct PRRowItem: View {
    let store: AppStore
    let item: AccountItem
    let checks: PRChecks?
    var openURL: (URL) -> Void

    /// Which inline action the row is currently morphed into. Merge and Approve both replace the
    /// row's middle region rather than popping a modal, matching the app's slide-in motion.
    private enum RowActionMode {
        case idle
        case merge
        case approve
    }

    @State private var expanded = false
    @State private var actionMode: RowActionMode = .idle
    @State private var approveMessage = ""
    /// The method whose merge is in flight, so only that button shows a spinner.
    @State private var submittingMethod: MergeMethod?
    /// Guards against duplicate submits from a rapid double-tap. Owned here (not in the
    /// hover-gated `PRQuickActions`) so it survives the accessory unmounting on hover-out.
    @State private var isSubmitting = false
    @FocusState private var approveFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Matches the idle `HoverRow`'s min height so morphing to the inline controls doesn't
    /// change the row's height (which would nudge the whole list up/down).
    @Environment(\.density) private var density

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

    /// The repo's enabled merge strategies for the inline picker; all three until the gate
    /// hydrates (optimistic — never offer fewer methods than the repo actually allows).
    private var allowedMergeMethods: [MergeMethod] {
        store.gate(for: item)?.allowedMergeMethods ?? MergeMethod.allCases
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                disclosure
                actionArea
            }
            if expanded {
                ForEach(checkModels) { model in
                    HoverRow { CheckRow(model: model) }
                        .padding(.leading, gutter)
                }
            }
        }
    }

    /// The morphing middle region: the normal row + hover actions when idle, or an inline
    /// merge-method picker / approve composer that replaces it.
    @ViewBuilder
    private var actionArea: some View {
        switch actionMode {
        case .idle:
            // The open-URL button and the quick-action buttons are siblings inside HoverRow
            // (not nested), so tapping Approve/Merge doesn't also fire the row's open-URL
            // action. The accessory only takes hits while revealed (see HoverRow).
            HoverRow(trailingAccessory: {
                PRQuickActions(
                    issue: issue,
                    isSubmitting: isSubmitting,
                    showApprove: showApprove,
                    showMerge: showMerge,
                    onApprove: { enterApprove() },
                    onMerge: { setMode(.merge) }
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
                        Button("Approve \(prLabel)") { enterApprove() }
                    }
                    if showMerge {
                        Button("Merge \(prLabel)") { setMode(.merge) }
                    }
                }
            })
        case .merge:
            MergeMethodBar(
                methods: allowedMergeMethods,
                submittingMethod: submittingMethod,
                isSubmitting: isSubmitting,
                onSelect: { method in
                    submittingMethod = method
                    submit {
                        await store.merge(item, method: method)
                        submittingMethod = nil
                        setMode(.idle)
                    }
                },
                onCancel: { setMode(.idle) }
            )
            .padding(.horizontal, Theme.Spacing.md)
            .frame(maxWidth: .infinity, minHeight: density.rowHeight, alignment: .trailing)
            .transition(.scale(scale: 0.7, anchor: .trailing).combined(with: .opacity))
        case .approve:
            HStack(spacing: Theme.Spacing.sm) {
                // A hidden state badge reserves exactly the leading space PRRow gives its own
                // badge, so the field's text lines up with the PR title above it.
                StateBadge(state: GitHubState(issue: issue), size: .small)
                    .hidden()
                    .accessibilityHidden(true)
                ApproveComposer(
                    message: $approveMessage,
                    isSubmitting: isSubmitting,
                    focus: $approveFocused,
                    onApprove: { runApprove() },
                    onCancel: {
                        approveMessage = ""
                        setMode(.idle)
                    }
                )
            }
            .padding(.horizontal, Theme.Spacing.md)
            .frame(maxWidth: .infinity, minHeight: density.rowHeight)
            .transition(.move(edge: .trailing).combined(with: .opacity))
        }
    }

    /// Change the inline action mode with the morph animation. Driven here (not via an ambient
    /// `.animation(value:)` modifier) so the animation only fires on an explicit action — an
    /// ambient modifier makes the `LazyVStack` animate rows as it recycles them mid-scroll.
    private func setMode(_ mode: RowActionMode) {
        withAnimation(Motion.respecting(reduceMotion, Motion.spring)) { actionMode = mode }
    }

    /// Enter the approve composer and focus its field. `approveFocused` is also set in the
    /// composer's `onAppear` (the reliable moment the field is mounted); setting it here too
    /// covers the case where the field is already present.
    private func enterApprove() {
        setMode(.approve)
        approveFocused = true
    }

    /// Submit the approval with the composed (optional) message, then reset back to idle.
    private func runApprove() {
        submit {
            await store.approve(item, message: approveMessage)
            approveMessage = ""
            setMode(.idle)
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
        if actionMode == .idle, !checkModels.isEmpty {
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

/// Hover-revealed quick actions for a PR row: Approve (checkmark) and Merge, each of which
/// asks the owning row to morph into its inline flow (an approve composer / a merge-method
/// picker) rather than acting immediately. Stateless: the submit guard and mode state live on
/// `PRRowItem` so they survive this view unmounting when hover ends.
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

/// The expanded merge-method picker: one button per strategy the repo enables. The whole group
/// scales out from the trailing edge (where the Merge button sat), so it reads as that button
/// expanding into the methods — buttons stay full-size, so labels never truncate mid-morph.
/// One tap merges immediately (confirmed — no second step). The first method carries the accent.
private struct MergeMethodBar: View {
    let methods: [MergeMethod]
    /// The method whose merge is in flight (drives that button's spinner), or nil.
    let submittingMethod: MergeMethod?
    let isSubmitting: Bool
    var onSelect: (MergeMethod) -> Void
    var onCancel: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            ForEach(Array(methods.enumerated()), id: \.element) { index, method in
                Button(method.label) { onSelect(method) }
                    .buttonStyle(GBButtonStyle(
                        variant: index == 0 ? .primary : .secondary,
                        isLoading: submittingMethod == method
                    ))
                    .fixedSize()
                    .accessibilityLabel("\(method.label) and merge")
            }
            Button { onCancel() } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(GBButtonStyle(variant: .icon))
            .gbTooltip("Cancel")
            .accessibilityLabel("Cancel merge")
        }
        .disabled(isSubmitting)
    }
}

/// The inline approval composer the row morphs into when Approve is tapped: a bare, underlined
/// comment field (no fill, so it reads as part of the row) plus Approve / cancel buttons.
/// Submitting with an empty body is allowed — it posts a plain approval.
private struct ApproveComposer: View {
    @Binding var message: String
    let isSubmitting: Bool
    var focus: FocusState<Bool>.Binding
    var onApprove: () -> Void
    var onCancel: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            TextField("Approval comment (optional)", text: $message)
                .textFieldStyle(.plain)
                .font(Theme.Typography.caption)
                .focused(focus)
                .onSubmit { onApprove() }
                .frame(maxWidth: .infinity)
                .frame(height: 26)
                // Just an underline — accented while focused — so the field feels inline rather
                // than a boxed control.
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(focus.wrappedValue ? Theme.Palette.accent : Surface.hairline)
                        .frame(height: 1)
                }

            Button { onApprove() } label: {
                Image(systemName: "checkmark")
            }
            .buttonStyle(GBButtonStyle(variant: .primary, isLoading: isSubmitting))
            .gbTooltip("Approve")
            .accessibilityLabel("Submit approval")

            Button { onCancel() } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(GBButtonStyle(variant: .icon))
            .gbTooltip("Cancel")
            .accessibilityLabel("Cancel approval")
        }
        .disabled(isSubmitting)
        // The field is only mounted once the row morphs to `.approve`; focus it on the next
        // runloop tick (after the morph settles) so the caret reliably lands without a click.
        // The menu-bar panel is key, so it receives keystrokes (see `SearchField`).
        .onAppear { DispatchQueue.main.async { focus.wrappedValue = true } }
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
