import SwiftUI

/// A small numeric pill for tab/section counts and the menu-bar badge. Zero renders
/// as nothing (a count badge for "0" is noise). The `emphasized` style tints it with
/// the link color for "unread"-type counts; otherwise it's a quiet neutral chip.
struct CountBadge: View {
    let value: Int
    var emphasized = false

    init(_ count: Int, emphasized: Bool = false) {
        value = count
        self.emphasized = emphasized
    }

    var body: some View {
        if value > 0 {
            Text(value, format: .number)
                .font(Theme.Typography.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(emphasized ? Theme.Palette.link : .secondary)
                .padding(.horizontal, Theme.Spacing.xs + 2)
                .padding(.vertical, 1)
                .background(
                    emphasized ? Theme.Palette.link.opacity(0.16) : Surface.controlFill,
                    in: Capsule()
                )
        }
    }
}

#if DEBUG
#Preview("CountBadge") {
    HStack(spacing: Theme.Spacing.md) {
        CountBadge(0)
        CountBadge(3)
        CountBadge(12, emphasized: true)
        CountBadge(128)
    }
    .padding(Theme.Spacing.lg)
}
#endif
