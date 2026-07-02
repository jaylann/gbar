import SwiftUI

/// A skeleton placeholder shaped like a real row, for the *first ever* load only —
/// afterwards the app should render cached content instantly and refresh in the
/// background. A gentle opacity pulse (disabled under Reduce Motion) signals "loading"
/// without a jarring spinner over content.
struct SkeletonRow: View {
    var reservesDisclosureGutter = false

    @State private var pulsing = false
    @Environment(\.density) private var density
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            if reservesDisclosureGutter {
                Color.clear
                    .frame(width: Theme.Spacing.lg, height: 1)
            }

            HStack(alignment: .center, spacing: Theme.Spacing.sm) {
                bar(width: 12, height: 12)
                VStack(alignment: .leading, spacing: 2) {
                    line(width: 210, barHeight: 10, font: Theme.Typography.rowTitle)
                    line(width: 120, barHeight: 8, font: Theme.Typography.caption)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, density.rowVerticalPadding)
        .frame(minHeight: density.rowHeight, alignment: .leading)
        .opacity(reduceMotion ? 0.6 : (pulsing ? 0.4 : 0.7))
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(Motion.pulse) { pulsing = true }
        }
        .accessibilityLabel("Loading")
    }

    private func bar(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
            .fill(Surface.controlFill)
            .frame(width: width, height: height)
    }

    /// Keep the placeholder's visual bar restrained while deriving its layout height from the
    /// exact font used by the corresponding row text. This prevents the skeleton from collapsing
    /// to the density minimum when a real two-line row is intrinsically taller.
    private func line(width: CGFloat, barHeight: CGFloat, font: Font) -> some View {
        Text("Placeholder")
            .font(font)
            .lineLimit(1)
            .hidden()
            .overlay(alignment: .leading) {
                bar(width: width, height: barHeight)
            }
    }
}

/// A short stack of skeleton rows for the initial load.
struct LoadingView: View {
    var rows = 4
    var reservesDisclosureGutter = false

    var body: some View {
        VStack(spacing: 2) {
            ForEach(0..<rows, id: \.self) { _ in
                SkeletonRow(reservesDisclosureGutter: reservesDisclosureGutter)
            }
        }
    }
}

#if DEBUG
#Preview("LoadingView") {
    LoadingView()
        .frame(width: 380)
        .padding(Theme.Spacing.sm)
}
#endif
