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
        .frame(maxWidth: .infinity, alignment: .leading)
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

/// A stack of skeleton rows for the initial load. Matches the real list's inter-row spacing
/// (`Theme.Spacing.sm`) so the placeholder reads like the content it stands in for.
struct LoadingView: View {
    /// Fixed count for the gallery/preview. When `fillsHeight` is set the count is derived
    /// from the available height instead, so the skeleton fills the tab like the real list.
    var rows = 4
    var fillsHeight = false
    var reservesDisclosureGutter = false

    @Environment(\.density) private var density

    var body: some View {
        if fillsHeight {
            GeometryReader { proxy in
                stack(count: rowCount(for: proxy.size.height))
                    .frame(maxWidth: .infinity, alignment: .top)
            }
        } else {
            stack(count: rows)
        }
    }

    private func stack(count: Int) -> some View {
        VStack(spacing: Theme.Spacing.sm) {
            ForEach(0..<count, id: \.self) { _ in
                SkeletonRow(reservesDisclosureGutter: reservesDisclosureGutter)
            }
        }
    }

    /// A `SkeletonRow` stacks two lines of text, so its real height exceeds the density floor
    /// (`rowHeight`, just a `minHeight`). Estimate the intrinsic height — biased slightly high so
    /// the fitted count rounds *down* and the bottom row is never clipped (the skeleton, unlike
    /// the real list, isn't scrollable).
    private var estimatedRowHeight: CGFloat {
        // rowTitle (~16) + 2pt VStack gap + caption (~13), rounded up.
        let twoLineText: CGFloat = 32
        return max(density.rowHeight, twoLineText + density.rowVerticalPadding * 2)
    }

    /// One skeleton per row-stride (row height + inter-row gap) that fits the body, clamped
    /// to a sensible floor so a short container still reads as a list.
    private func rowCount(for height: CGFloat) -> Int {
        let stride = estimatedRowHeight + Theme.Spacing.sm
        guard stride > 0, height > 0 else { return rows }
        return max(rows, Int((height + Theme.Spacing.sm) / stride))
    }
}

#if DEBUG
#Preview("LoadingView") {
    LoadingView()
        .frame(width: 380)
        .padding(Theme.Spacing.sm)
}
#endif
