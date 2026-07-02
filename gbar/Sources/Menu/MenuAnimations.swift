import SwiftUI

/// The popover's transition wiring — the tab-body swap and the filter-change list animation —
/// split out of `MenuContentView` to keep that file within the file-length limit.
extension MenuContentView {
    /// Every tab's body, kept alive in a horizontal pager and slid into place — the selected tab
    /// sits at rest, the others park one popover-width off to the side matching their order. This
    /// replaces the old `.id(selectedTab)` swap, which gave each tab a fresh identity and so
    /// *rebuilt* its whole (eager) list on every switch — the navigation hitch on a busy PR tab.
    /// Here each list is built once and switching only re-offsets already-realized bodies, so
    /// navigation stays smooth however many rows a tab holds. `.animation(value:)` supplies the
    /// curve (the `@AppStorage`-backed selection can't carry a `withAnimation` transaction), and
    /// `.clipped()` hides the parked bodies. Non-selected tabs drop hit-testing and accessibility
    /// so only the visible one is interactive.
    var animatedTabContent: some View {
        ZStack {
            ForEach(MenuTab.allCases, id: \.self) { tab in
                tabContent(for: tab)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(tab == selectedTab ? 1 : 0)
                    .offset(x: tabOffset(for: tab))
                    .allowsHitTesting(tab == selectedTab)
                    .accessibilityHidden(tab != selectedTab)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .animation(Motion.respecting(reduceMotion, Motion.tabSwitch), value: selectedTab)
    }

    /// Resting x-offset for a tab in the pager: `0` for the selected tab, and one popover-width to
    /// the left/right for tabs ordered before/after it — so a switch slides the incoming body in
    /// from the correct side (and the outgoing one out the other), whatever the index distance.
    private func tabOffset(for tab: MenuTab) -> CGFloat {
        let all = MenuTab.allCases
        guard let index = all.firstIndex(of: tab), let selected = all.firstIndex(of: selectedTab) else {
            return 0
        }
        if index == selected { return 0 }
        return index > selected ? Theme.Layout.popoverWidth : -Theme.Layout.popoverWidth
    }
}
