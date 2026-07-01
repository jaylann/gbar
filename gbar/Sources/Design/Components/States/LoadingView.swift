import SwiftUI

/// A skeleton placeholder shaped like a real row, for the *first ever* load only —
/// afterwards the app should render cached content instantly and refresh in the
/// background. A gentle opacity pulse (disabled under Reduce Motion) signals "loading"
/// without a jarring spinner over content.
struct SkeletonRow: View {
    @State private var pulsing = false
    @Environment(\.density) private var density
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.sm) {
            bar(width: 12, height: 12)
            VStack(alignment: .leading, spacing: 6) {
                bar(width: 210, height: 10)
                bar(width: 120, height: 8)
            }
            Spacer(minLength: 0)
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
        RoundedRectangle(cornerRadius: Theme.Radius.sm)
            .fill(Surface.controlFill)
            .frame(width: width, height: height)
    }
}

/// A short stack of skeleton rows for the initial load.
struct LoadingView: View {
    var rows = 4

    var body: some View {
        VStack(spacing: 2) {
            ForEach(0..<rows, id: \.self) { _ in SkeletonRow() }
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
