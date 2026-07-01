import SwiftUI

/// The workhorse list-row container. Every PR/issue/notification/check row and every
/// tappable menu item composes from it, so hover + keyboard-focus feedback is defined
/// once. Fills `Surface.rowHover` under the pointer and `Surface.selection` + a focus
/// ring when keyboard-focused. Height and inner padding follow the ambient
/// `DensityMode`. Motion respects Reduce Motion.
struct HoverRow<Content: View>: View {
    /// Driven by keyboard navigation (↑/↓). When true the row reads as "selected".
    var isFocused = false
    @ViewBuilder var content: () -> Content

    @State private var isHovering = false
    @Environment(\.density) private var density
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        content()
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, density.rowVerticalPadding)
            .frame(minHeight: density.rowHeight, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(fill, in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
            .overlay {
                if isFocused {
                    RoundedRectangle(cornerRadius: Theme.Radius.sm)
                        .strokeBorder(Surface.focusRing, lineWidth: 1)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
            .onHover { isHovering = $0 }
            .animation(Motion.respecting(reduceMotion, Motion.hover), value: isHovering)
            .animation(Motion.respecting(reduceMotion, Motion.hover), value: isFocused)
    }

    private var fill: Color {
        if isFocused { return Surface.selection }
        return isHovering ? Surface.rowHover : .clear
    }
}

#if DEBUG
#Preview("HoverRow") {
    VStack(spacing: 2) {
        HoverRow { Text("Default row — hover me").font(Theme.Typography.rowTitle) }
        HoverRow(isFocused: true) {
            Text("Keyboard-focused row").font(Theme.Typography.rowTitle)
        }
        HoverRow { Text("Another row").font(Theme.Typography.rowTitle) }
    }
    .padding(Theme.Spacing.sm)
    .frame(width: 380)
}
#endif
