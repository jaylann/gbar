import SwiftUI

/// A Primer-style state pill: state color + shape + label in a tinted capsule. The
/// analog of GitHub's StateLabel. `.small` drops the label to just the colored glyph
/// for dense rows; `.normal` shows the full pill for headers and detail.
struct StateBadge: View {
    let state: GitHubState
    var size: Size = .normal

    enum Size {
        case normal
        case small
    }

    var body: some View {
        switch size {
        case .normal:
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: state.symbol)
                Text(state.label)
            }
            .font(Theme.Typography.caption.weight(.medium))
            .foregroundStyle(state.color)
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, 2)
            .background(state.color.opacity(0.14), in: Capsule())
        case .small:
            Image(systemName: state.symbol)
                .font(Theme.Typography.caption)
                .foregroundStyle(state.color)
                .accessibilityLabel(state.label)
        }
    }
}

#if DEBUG
#Preview("StateBadge") {
    let states: [GitHubState] = [.open, .draft, .merged, .closed, .done]
    return VStack(alignment: .leading, spacing: Theme.Spacing.md) {
        HStack(spacing: Theme.Spacing.sm) {
            ForEach(Array(states.enumerated()), id: \.offset) { _, state in
                StateBadge(state: state)
            }
        }
        HStack(spacing: Theme.Spacing.md) {
            ForEach(Array(states.enumerated()), id: \.offset) { _, state in
                StateBadge(state: state, size: .small)
            }
        }
    }
    .padding(Theme.Spacing.lg)
}
#endif
