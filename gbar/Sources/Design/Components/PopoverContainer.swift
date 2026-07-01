import SwiftUI

/// The root frame for the menu-bar popover. Fixes the width to a menu-bar-appropriate
/// 380pt and lets height grow with content up to a cap, past which the caller scrolls
/// internally (a menu-bar panel shouldn't grow into a misplaced window). Sets the
/// default row density for everything inside.
struct PopoverContainer<Content: View>: View {
    var width: CGFloat = 380
    var maxHeight: CGFloat = 520
    var density: DensityMode = .compact
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .frame(width: width)
            .frame(maxHeight: maxHeight)
            // Opaque base so the translucent MenuBarExtra material doesn't let the
            // desktop bleed through and muddy the palette. The window masks corners.
            .background(Surface.canvas)
            .density(density)
    }
}

#if DEBUG
#Preview("PopoverContainer") {
    PopoverContainer {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Awaiting your review", count: 2)
            HoverRow { PRRow(issue: .previewOpenPR, ci: .success, isUnseen: true) }
            HoverRow { PRRow(issue: .previewDraftPR, ci: .pending) }
            SectionHeader(title: "Your open PRs", count: 1)
            HoverRow { PRRow(issue: .previewMergedPR) }
        }
        .padding(Theme.Spacing.sm)
    }
}
#endif
