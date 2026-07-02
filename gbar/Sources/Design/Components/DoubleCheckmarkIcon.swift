import SwiftUI

/// Custom double-checkmark glyph (the "mark all as read" affordance) — the back check is
/// cleanly cut off behind the front one via a destination-out mask. Built from two SF Symbol
/// checkmarks so it inherits the surrounding font size/weight like any other icon.
struct DoubleCheckmarkIcon: View {
    var body: some View {
        ZStack(alignment: .leading) {
            // Back checkmark, masked to hide where it overlaps the front.
            Image(systemName: "checkmark")
                .fontWeight(.semibold)
                .offset(x: 7)
                .mask {
                    Rectangle()
                        .padding(-20)
                        .overlay {
                            Image(systemName: "checkmark")
                                .fontWeight(.black)
                                .padding(.leading, 10)
                                .padding(.trailing, 2)
                                .padding(.vertical, 2)
                                .offset(x: -7)
                                .blendMode(.destinationOut)
                        }
                        .compositingGroup()
                }
            // Front checkmark on top.
            Image(systemName: "checkmark")
                .fontWeight(.semibold)
        }
        // The back check is rendered 7pt right via `.offset` (which doesn't grow the layout
        // bounds), so reserve that width on the trailing side — otherwise the glyph overflows
        // its box to the right and looks left-shifted when the button centers it.
        .padding(.trailing, 7)
    }
}
