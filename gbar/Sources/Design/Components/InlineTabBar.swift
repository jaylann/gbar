import SwiftUI

/// A clean, inline top-level tab bar: the top-level tabs in one row, thin separators
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
        HStack(spacing: Theme.Spacing.sm) {
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
                // Render the visible label at the current weight, but always reserve the
                // *semibold* width via a hidden twin behind it (ZStack sizes to its widest
                // child). Otherwise selecting a tab swaps regular→semibold and the wider text
                // reflows the whole row ("wiggle").
                ZStack {
                    label(tab, weight: .semibold).hidden()
                    label(tab, weight: selected ? .semibold : .regular)
                        .foregroundStyle(selected ? Theme.Palette.accent : .secondary)
                }
                // Keep every tab on one line: labels take their intrinsic width and never wrap,
                // so five tabs + counts stay a single row in the fixed-width popover.
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

                // Invisible per-tab anchor: gives the shared underline a frame (this tab's
                // label width × 2pt) to match. Also reserves the row height so labels hold still.
                Color.clear
                    .frame(height: 2)
                    .matchedGeometryEffect(id: tab.tag, in: underline, isSource: true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Mark the active tab for VoiceOver — selection is otherwise only colour + underline.
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// The tab's title + optional count at a given weight. Used twice per tab: a hidden
    /// semibold twin to reserve width, and the visible copy at the selection-driven weight.
    private func label(_ tab: Tab, weight: Font.Weight) -> some View {
        HStack(spacing: Theme.Spacing.xs) {
            Text(tab.title)
            if let count = tab.count {
                Text("\(count)")
                    .monospacedDigit()
            }
        }
        .font(Theme.Typography.rowTitle.weight(weight))
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
