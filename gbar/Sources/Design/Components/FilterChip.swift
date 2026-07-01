import SwiftUI

/// A low-commitment capsule toggle for cross-cutting filters (Open · Draft · Failing ·
/// Mine · @mentions). On = accent-tinted; off = quiet neutral. Meant to sit in a
/// scrollable row above a list.
struct FilterChip: View {
    let title: String
    var symbol: String?
    @Binding var isOn: Bool

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: Theme.Spacing.xs) {
                if let symbol {
                    Image(systemName: symbol)
                }
                Text(title)
            }
            .font(Theme.Typography.caption.weight(isOn ? .semibold : .regular))
            .foregroundStyle(isOn ? Theme.Palette.accent : .secondary)
            .padding(.horizontal, Theme.Spacing.sm)
            .frame(height: 22)
            .background(background, in: Capsule())
            .overlay {
                Capsule().strokeBorder(isOn ? Theme.Palette.accent.opacity(0.5) : Surface.hairline, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(Motion.respecting(reduceMotion, Motion.hover), value: isOn)
        .animation(Motion.respecting(reduceMotion, Motion.hover), value: isHovering)
    }

    private var background: Color {
        if isOn { return Theme.Palette.accent.opacity(0.14) }
        return isHovering ? Surface.controlHover : .clear
    }
}

#if DEBUG
private struct FilterChipPreview: View {
    @State private var open = true
    @State private var draft = false
    @State private var failing = false
    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            FilterChip(title: "Open", symbol: "smallcircle.filled.circle", isOn: $open)
            FilterChip(title: "Draft", isOn: $draft)
            FilterChip(title: "Failing", symbol: "xmark.circle", isOn: $failing)
        }
        .padding(Theme.Spacing.lg)
    }
}

#Preview("FilterChip") { FilterChipPreview() }
#endif
