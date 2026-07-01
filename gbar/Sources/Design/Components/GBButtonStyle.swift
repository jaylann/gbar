import SwiftUI

/// The button styling for the whole app, as a `ButtonStyle` so it drops onto any
/// `Button`. Four variants — `primary` (accent fill), `secondary` (subtle fill),
/// `ghost` (text that fills on hover), and `icon` (square symbol button). Handles
/// hover, pressed, disabled, and a `loading` state that swaps the label for a spinner
/// without changing the button's width.
struct GBButtonStyle: ButtonStyle {
    enum Variant {
        case primary
        case secondary
        case ghost
        case icon
    }

    var variant: Variant = .primary
    var isLoading = false

    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration, variant: variant, isLoading: isLoading)
    }

    private struct StyledLabel: View {
        let configuration: ButtonStyle.Configuration
        let variant: Variant
        let isLoading: Bool

        @State private var isHovering = false
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .font(Theme.Typography.caption.weight(.medium))
                .opacity(isLoading ? 0 : 1)
                .overlay { if isLoading { ProgressView().controlSize(.small) } }
                .padding(.horizontal, variant == .icon ? 0 : Theme.Spacing.md)
                .frame(height: 28)
                .frame(width: variant == .icon ? 28 : nil)
                .foregroundStyle(foreground)
                .background(background, in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
                .opacity(isEnabled ? 1 : 0.4)
                .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
                .onHover { isHovering = $0 }
                .animation(Motion.respecting(reduceMotion, Motion.hover), value: isHovering)
                .animation(Motion.respecting(reduceMotion, Motion.hover), value: configuration.isPressed)
        }

        private var isPressed: Bool {
            configuration.isPressed
        }

        private var foreground: Color {
            switch variant {
            case .primary: .white
            case .ghost,
                 .icon,
                 .secondary: .primary
            }
        }

        private var background: Color {
            switch variant {
            case .primary:
                Theme.Palette.accent.opacity(isPressed ? 0.8 : (isHovering ? 0.92 : 1))
            case .secondary:
                isPressed ? Surface.controlPressed : (isHovering ? Surface.controlHover : Surface.controlFill)
            case .ghost,
                 .icon:
                isPressed ? Surface.controlPressed : (isHovering ? Surface.controlHover : .clear)
            }
        }
    }
}

#if DEBUG
#Preview("GBButtonStyle") {
    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
        HStack(spacing: Theme.Spacing.sm) {
            Button("Merge") {}.buttonStyle(GBButtonStyle(variant: .primary))
            Button("Approve") {}.buttonStyle(GBButtonStyle(variant: .secondary))
            Button("Dismiss") {}.buttonStyle(GBButtonStyle(variant: .ghost))
            Button {} label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(GBButtonStyle(variant: .icon))
        }
        HStack(spacing: Theme.Spacing.sm) {
            Button("Loading") {}.buttonStyle(GBButtonStyle(variant: .primary, isLoading: true))
            Button("Disabled") {}.buttonStyle(GBButtonStyle(variant: .secondary)).disabled(true)
        }
    }
    .padding(Theme.Spacing.xl)
}
#endif
