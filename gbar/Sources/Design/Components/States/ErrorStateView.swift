import SwiftUI

/// A recoverable error state. Categorized so the copy and the recovery action fit the
/// failure — a rate-limit shows when it resets; an expired token routes to sign-in.
struct ErrorStateView: View {
    enum Kind {
        case network
        case authExpired
        case rateLimited(resetsIn: String)
        case generic

        var symbol: String {
            switch self {
            case .network: "wifi.exclamationmark"
            case .authExpired: "person.badge.key"
            case .rateLimited: "hourglass"
            case .generic: "exclamationmark.triangle"
            }
        }

        var title: String {
            switch self {
            case .network: "Can't reach GitHub"
            case .authExpired: "Session expired"
            case .rateLimited: "Rate limit reached"
            case .generic: "Something went wrong"
            }
        }

        var message: String {
            switch self {
            case .network: "Check your connection and try again."
            case .authExpired: "Sign in again to keep syncing."
            case let .rateLimited(resetsIn): "GitHub's API limit is hit. Resets in \(resetsIn)."
            case .generic: "The last refresh didn't complete."
            }
        }
    }

    let kind: Kind
    var retryTitle = "Retry"
    var onRetry: (() -> Void)?

    var body: some View {
        VStack(spacing: Theme.Spacing.sm) {
            Image(systemName: kind.symbol)
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(Theme.Palette.pending)
            Text(kind.title)
                .font(Theme.Typography.rowTitle)
                .foregroundStyle(.primary)
            Text(kind.message)
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let onRetry {
                Button(retryTitle, action: onRetry)
                    .buttonStyle(GBButtonStyle(variant: .secondary))
                    .padding(.top, Theme.Spacing.xs)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Spacing.xl)
        .padding(.horizontal, Theme.Spacing.lg)
    }
}

#if DEBUG
#Preview("ErrorStateView") {
    VStack(spacing: Theme.Spacing.md) {
        ErrorStateView(kind: .network) {}
        Divider()
        ErrorStateView(kind: .rateLimited(resetsIn: "12m")) {}
    }
    .frame(width: 380)
    .padding(Theme.Spacing.sm)
}
#endif
