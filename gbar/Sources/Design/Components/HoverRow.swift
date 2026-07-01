import SwiftUI

/// The workhorse list-row container. Every PR/issue/notification/check row and every
/// tappable menu item composes from it, so hover + keyboard-focus feedback is defined
/// once. Fills `Surface.rowHover` under the pointer and `Surface.selection` + a focus
/// ring when keyboard-focused. Height and inner padding follow the ambient
/// `DensityMode`. Motion respects Reduce Motion.
struct HoverRow<Accessory: View, Content: View>: View {
    /// Driven by keyboard navigation (↑/↓). When true the row reads as "selected".
    var isFocused = false
    /// Optional trailing controls (e.g. quick-action buttons) revealed on hover/focus and
    /// overlaid at the row's trailing edge.
    private let trailingAccessory: () -> Accessory
    private let content: () -> Content

    init(
        isFocused: Bool = false,
        @ViewBuilder trailingAccessory: @escaping () -> Accessory,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.isFocused = isFocused
        self.trailingAccessory = trailingAccessory
        self.content = content
    }

    @State private var isHovering = false
    @Environment(\.density) private var density
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Reveal the accessory under the pointer or when keyboard-focused, so it's reachable
    /// without a mouse.
    private var accessoryVisible: Bool {
        isHovering || isFocused
    }

    var body: some View {
        content()
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, density.rowVerticalPadding)
            .frame(minHeight: density.rowHeight, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(fill, in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
            .overlay(alignment: .trailing) {
                trailingAccessory()
                    .padding(.trailing, Theme.Spacing.md)
                    .opacity(accessoryVisible ? 1 : 0)
                    .allowsHitTesting(accessoryVisible)
            }
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

extension HoverRow where Accessory == EmptyView {
    /// Convenience for rows without a trailing accessory, so existing `HoverRow { content }`
    /// call sites keep compiling unchanged.
    init(isFocused: Bool = false, @ViewBuilder content: @escaping () -> Content) {
        self.init(isFocused: isFocused, trailingAccessory: { EmptyView() }, content: content)
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
