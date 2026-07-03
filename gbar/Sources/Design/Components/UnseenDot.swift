import SwiftUI

/// PullBar's unseen-changes primitive: a 7pt link-colored dot marking a row with
/// something new. Fades out (not pops out) when the row becomes seen. Reserves its
/// footprint when hidden so titles don't shift as items are read.
struct UnseenDot: View {
    var isUnseen: Bool

    private let diameter: CGFloat = 7

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .fill(Theme.Palette.link)
            .frame(width: diameter, height: diameter)
            .opacity(isUnseen ? 1 : 0)
            .animation(Motion.respecting(reduceMotion, Motion.fade), value: isUnseen)
            // Hide the decorative dot from VoiceOver entirely when seen — an empty label would
            // still leave an (unlabeled) element in the a11y tree.
            .accessibilityLabel(Text("Unseen"))
            .accessibilityHidden(!isUnseen)
    }
}

#if DEBUG
#Preview("UnseenDot") {
    HStack(spacing: Theme.Spacing.lg) {
        UnseenDot(isUnseen: true)
        UnseenDot(isUnseen: false)
    }
    .padding(Theme.Spacing.xl)
}
#endif
