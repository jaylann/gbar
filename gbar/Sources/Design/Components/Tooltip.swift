import SwiftUI

/// A small hover tooltip that fades in after a short dwell, styled on the design tokens.
/// Used instead of the native macOS help tag, which doesn't match the popover's look and
/// can't be themed. Purely informational — never takes hits.
private struct TooltipModifier: ViewModifier {
    let text: String
    var edge: VerticalEdge = .top

    /// Dwell before showing, so tooltips don't flicker as the pointer sweeps across controls.
    private static let dwell = Duration.milliseconds(500)

    @State private var isHovering = false
    @State private var isVisible = false
    @State private var dwellTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                isHovering = hovering
                dwellTask?.cancel()
                if hovering {
                    dwellTask = Task { @MainActor in
                        try? await Task.sleep(for: Self.dwell)
                        guard !Task.isCancelled, isHovering else { return }
                        withAnimation(Motion.respecting(reduceMotion, Motion.fade)) { isVisible = true }
                    }
                } else {
                    withAnimation(Motion.respecting(reduceMotion, Motion.fade)) { isVisible = false }
                }
            }
            .overlay(alignment: edge == .top ? .top : .bottom) {
                if isVisible {
                    label
                        .fixedSize()
                        .offset(y: edge == .top ? -30 : 30)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
            // Don't let a pending dwell fire after the row scrolls away or the tab switches.
            .onDisappear {
                dwellTask?.cancel()
                isVisible = false
            }
    }

    private var label: some View {
        Text(text)
            .font(Theme.Typography.caption)
            .foregroundStyle(.primary)
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, 3)
            .background(Surface.canvas, in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm).strokeBorder(Surface.hairline))
            .shadow(color: .black.opacity(0.22), radius: 4, y: 2)
    }
}

extension View {
    /// Show a styled tooltip after a ~0.5s hover dwell — the in-popover replacement for
    /// `.help`. `edge` picks which side it floats to (use `.bottom` near the popover top).
    func gbTooltip(_ text: String, edge: VerticalEdge = .top) -> some View {
        modifier(TooltipModifier(text: text, edge: edge))
    }
}

#if DEBUG
#Preview("Tooltip") {
    HStack(spacing: Theme.Spacing.xl) {
        Button {} label: { Image(systemName: "checkmark") }
            .buttonStyle(GBButtonStyle(variant: .secondary))
            .gbTooltip("Approve")
        Button {} label: { Image(systemName: "arrow.clockwise") }
            .buttonStyle(GBButtonStyle(variant: .icon))
            .gbTooltip("Refresh", edge: .bottom)
    }
    .padding(Theme.Spacing.xl)
}
#endif
