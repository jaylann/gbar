import SwiftUI

/// The status of a CI check run. Like `GitHubState`, color is always paired with a
/// shape so it survives color-blindness and menu-bar tinting.
enum CIStatus {
    case success
    case failure
    case pending
    case neutral
    case error

    var color: Color {
        switch self {
        case .success: Theme.Palette.open
        case .error,
             .failure: Theme.Palette.closed
        case .pending: Theme.Palette.pending
        case .neutral: Theme.Palette.draft
        }
    }

    var symbol: String {
        switch self {
        case .success: "checkmark.circle.fill"
        case .failure: "xmark.circle.fill"
        case .pending: "circle.dashed"
        case .neutral: "minus.circle.fill"
        case .error: "exclamationmark.triangle.fill"
        }
    }

    var label: String {
        switch self {
        case .success: "Passing"
        case .failure: "Failing"
        case .pending: "Running"
        case .neutral: "Skipped"
        case .error: "Errored"
        }
    }

    var isRunning: Bool {
        self == .pending
    }
}

/// A single CI status glyph. The *running* state gently pulses so motion reads as
/// "something is happening"; passing/failing are static. Reduce Motion disables the
/// pulse.
struct CIStatusIndicator: View {
    let status: CIStatus

    @State private var pulsing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: status.symbol)
            .font(Theme.Typography.caption)
            .foregroundStyle(status.color)
            .opacity(status.isRunning && pulsing && !reduceMotion ? 0.45 : 1)
            .animation(status.isRunning && !reduceMotion ? Motion.pulse : nil, value: pulsing)
            .onAppear { if status.isRunning { pulsing = true } }
            .accessibilityLabel(status.label)
    }
}

#if DEBUG
#Preview("CIStatusIndicator") {
    let all: [CIStatus] = [.success, .failure, .pending, .neutral, .error]
    return HStack(spacing: Theme.Spacing.lg) {
        ForEach(Array(all.enumerated()), id: \.offset) { _, status in
            VStack(spacing: Theme.Spacing.xs) {
                CIStatusIndicator(status: status)
                Text(status.label).font(Theme.Typography.caption).foregroundStyle(.secondary)
            }
        }
    }
    .padding(Theme.Spacing.xl)
}
#endif
