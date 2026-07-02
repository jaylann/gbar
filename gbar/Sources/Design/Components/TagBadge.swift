import SwiftUI

/// A tiny text capsule for short metadata tags ("PRs", "Issues", "Auto") — the textual sibling
/// of `CountBadge`. Quiet by default; `emphasized` tints it with the link color for tags that
/// should read as active.
struct TagBadge: View {
    let text: String
    var emphasized = false

    init(_ text: String, emphasized: Bool = false) {
        self.text = text
        self.emphasized = emphasized
    }

    var body: some View {
        Text(text)
            .font(Theme.Typography.caption.weight(.medium))
            .foregroundStyle(emphasized ? Theme.Palette.link : .secondary)
            .padding(.horizontal, Theme.Spacing.xs + 2)
            .padding(.vertical, 1)
            .background(
                emphasized ? Theme.Palette.link.opacity(0.16) : Surface.controlFill,
                in: Capsule()
            )
    }
}

#if DEBUG
#Preview("TagBadge") {
    HStack(spacing: Theme.Spacing.sm) {
        TagBadge("PRs")
        TagBadge("Issues")
        TagBadge("Auto → PRs")
        TagBadge("Active", emphasized: true)
    }
    .padding(Theme.Spacing.lg)
}
#endif
