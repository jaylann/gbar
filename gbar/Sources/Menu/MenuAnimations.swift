import SwiftUI

/// The popover's transition wiring — the tab-body swap and the filter-change list animation —
/// split out of `MenuContentView` to keep that file within the file-length limit.
extension MenuContentView {
    /// `tabContent` under a directional slide. `.id(selectedTab)` gives each tab its own identity
    /// so switching removes the old body and inserts the new one (the transition then plays); the
    /// `ZStack` keeps both on screen through the crossfade; and `.animation(value:)` supplies the
    /// curve — the `@AppStorage`-backed selection can't carry a `withAnimation` transaction, so
    /// the animation is driven off the value change (the same tactic the tab underline uses). The
    /// fill frame lives here so both crossfading bodies share one frame.
    var animatedTabContent: some View {
        ZStack {
            tabContent
                .id(selectedTab)
                .transition(Motion.softSlide(forward: tabForward, reduceMotion: reduceMotion))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(Motion.respecting(reduceMotion, Motion.tabSwitch), value: selectedTab)
    }
}
