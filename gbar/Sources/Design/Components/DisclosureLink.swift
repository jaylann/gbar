import SwiftUI

/// A quiet caption-styled disclosure toggle: a rotating chevron + label that reveals optional
/// content below. Used to keep advanced fields off the common path (e.g. the OAuth client ID
/// and Enterprise host in Settings) without a heavy `GroupBox`/`DisclosureGroup` look.
struct DisclosureLink: View {
    let title: String
    @Binding var isExpanded: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            withAnimation(Motion.respecting(reduceMotion, Motion.spring)) { isExpanded.toggle() }
        } label: {
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                Text(title)
            }
            .font(Theme.Typography.caption)
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
    }
}

#if DEBUG
private struct DisclosureLinkPreview: View {
    @State private var isExpanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            DisclosureLink(title: "Advanced", isExpanded: $isExpanded)
            if isExpanded {
                Text("Revealed content").font(Theme.Typography.caption)
            }
        }
        .padding(Theme.Spacing.lg)
        .frame(width: 320, alignment: .leading)
    }
}

#Preview("DisclosureLink") { DisclosureLinkPreview() }
#endif
