import SwiftUI

/// A clean, inline top-level tab bar: `PRs | Issues | Inbox` in one row, thin separators
/// between them, the selected label in the accent color with a sliding underline. The
/// underline is one shape shared across tabs via `matchedGeometryEffect`, so it glides
/// (and resizes) to the tapped tab with a spring. Counts ride quietly beside each label.
struct InlineTabBar<Tag: Hashable>: View {
    struct Tab: Identifiable {
        let tag: Tag
        let title: String
        var count: Int?
        var id: Tag {
            tag
        }
    }

    let tabs: [Tab]
    @Binding var selection: Tag

    @Namespace private var underline
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                if index > 0 {
                    Rectangle()
                        .fill(Surface.hairline)
                        .frame(width: 1, height: 10)
                }
                tabButton(tab)
            }
        }
        // One persistent underline that snaps (isSource: false) to whichever tab's anchor
        // matches `selection`. Because it's a single view whose target frame changes, it
        // slides and resizes between tabs instead of fading out-and-in.
        .overlay(alignment: .bottomLeading) {
            Capsule()
                .fill(Theme.Palette.accent)
                .frame(height: 2)
                .matchedGeometryEffect(id: selection, in: underline, isSource: false)
        }
        // Drive the slide off the value: the @AppStorage-backed binding won't carry a
        // withAnimation transaction reliably, but this animates whenever `selection` changes.
        .animation(Motion.respecting(reduceMotion, Motion.spring), value: selection)
    }

    private func tabButton(_ tab: Tab) -> some View {
        let selected = tab.tag == selection
        return Button {
            selection = tab.tag
        } label: {
            VStack(spacing: 5) {
                HStack(spacing: Theme.Spacing.xs) {
                    Text(tab.title)
                    if let count = tab.count {
                        Text("\(count)")
                            .monospacedDigit()
                    }
                }
                .font(Theme.Typography.rowTitle.weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? Theme.Palette.accent : .secondary)

                // Invisible per-tab anchor: gives the shared underline a frame (this tab's
                // label width × 2pt) to match. Also reserves the row height so labels hold still.
                Color.clear
                    .frame(height: 2)
                    .matchedGeometryEffect(id: tab.tag, in: underline, isSource: true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#if DEBUG
private struct InlineTabBarPreview: View {
    @State private var selection = "prs"
    var body: some View {
        InlineTabBar(
            tabs: [
                .init(tag: "prs", title: "PRs", count: 86),
                .init(tag: "issues", title: "Issues", count: 28),
                .init(tag: "inbox", title: "Inbox", count: 50),
            ],
            selection: $selection
        )
        .padding(Theme.Spacing.lg)
        .frame(width: 420)
    }
}

#Preview("InlineTabBar") { InlineTabBarPreview() }
#endif
