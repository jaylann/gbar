import SwiftUI

/// Empty ≠ blank. A centered symbol + reassuring copy, with an optional action. The
/// `.caughtUp` intent is a small reward (accent check, gentle scale-in) so inbox-zero
/// feels earned; `.neutral` is a quiet "nothing here yet."
struct EmptyStateView: View {
    enum Intent {
        case neutral
        case caughtUp

        var symbol: String {
            switch self {
            case .neutral: "tray"
            case .caughtUp: "checkmark.circle"
            }
        }

        var tint: Color {
            switch self {
            case .neutral: .secondary
            case .caughtUp: Theme.Palette.open
            }
        }
    }

    var intent: Intent = .neutral
    let title: String
    var message: String?
    var actionTitle: String?
    var action: (() -> Void)?

    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: Theme.Spacing.sm) {
            Image(systemName: intent.symbol)
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(intent.tint)
            Text(title)
                .font(Theme.Typography.rowTitle)
                .foregroundStyle(.primary)
            if let message {
                Text(message)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(GBButtonStyle(variant: .secondary))
                    .padding(.top, Theme.Spacing.xs)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Spacing.xl)
        .padding(.horizontal, Theme.Spacing.lg)
        .scaleEffect(appeared || reduceMotion ? 1 : 0.98)
        .opacity(appeared || reduceMotion ? 1 : 0)
        .onAppear {
            withAnimation(Motion.respecting(reduceMotion, Motion.fade)) { appeared = true }
        }
    }
}

#if DEBUG
#Preview("EmptyStateView") {
    VStack(spacing: Theme.Spacing.lg) {
        EmptyStateView(intent: .caughtUp, title: "You're all caught up", message: "No reviews need you right now.")
        Divider()
        EmptyStateView(
            intent: .neutral,
            title: "No open PRs",
            message: "Pull requests you open will show up here.",
            actionTitle: "Open GitHub"
        ) {}
    }
    .frame(width: 380)
    .padding(Theme.Spacing.sm)
}
#endif
