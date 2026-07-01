import SwiftUI

/// The top-level domain switcher (PRs · Issues · Checks · Inbox). One glanceable row
/// in ~380pt — cheaper than a tab bar and it doesn't eat width like a sidebar. The
/// selection pill slides between segments with a subtle spring; each segment can carry
/// an SF Symbol and a count.
struct GBSegmentedControl<Tag: Hashable>: View {
    struct Segment: Identifiable {
        let tag: Tag
        let title: String
        var symbol: String?
        var count: Int?
        var id: Tag {
            tag
        }
    }

    let segments: [Segment]
    @Binding var selection: Tag

    @Namespace private var pill
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(segments) { segment in
                segmentButton(segment)
            }
        }
        .padding(2)
        .background(Surface.controlFill, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
    }

    private func segmentButton(_ segment: Segment) -> some View {
        let isSelected = segment.tag == selection
        return Button {
            withAnimation(Motion.respecting(reduceMotion, Motion.spring)) { selection = segment.tag }
        } label: {
            HStack(spacing: Theme.Spacing.xs) {
                if let symbol = segment.symbol {
                    Image(systemName: symbol)
                }
                Text(segment.title)
                if let count = segment.count {
                    CountBadge(count, emphasized: isSelected)
                }
            }
            .font(Theme.Typography.caption.weight(isSelected ? .semibold : .regular))
            .foregroundStyle(isSelected ? Color.primary : .secondary)
            .padding(.horizontal, Theme.Spacing.sm)
            .frame(height: 24)
            .frame(maxWidth: .infinity)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: Theme.Radius.sm)
                        .fill(Color(nsColor: .controlBackgroundColor))
                        .shadow(color: .black.opacity(0.12), radius: 1, y: 0.5)
                        .matchedGeometryEffect(id: "pill", in: pill)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

#if DEBUG
private struct SegmentedPreview: View {
    @State private var selection = "prs"
    var body: some View {
        GBSegmentedControl(
            segments: [
                .init(tag: "prs", title: "PRs", symbol: "arrow.triangle.pull", count: 4),
                .init(tag: "issues", title: "Issues", symbol: "smallcircle.filled.circle"),
                .init(tag: "checks", title: "Checks", symbol: "checkmark.seal"),
                .init(tag: "inbox", title: "Inbox", symbol: "bell", count: 2),
            ],
            selection: $selection
        )
        .padding(Theme.Spacing.lg)
        .frame(width: 380)
    }
}

#Preview("GBSegmentedControl") { SegmentedPreview() }
#endif
