import SwiftUI

/// Row density. Developers want compact — so `.compact` (32pt rows) is the default and
/// `.comfortable` (44pt) is the opt-in. Threaded through the environment so any row
/// composed from `HoverRow` picks it up without prop-drilling.
enum DensityMode: String, CaseIterable {
    case compact
    case comfortable

    /// Minimum row height for this density.
    var rowHeight: CGFloat {
        switch self {
        case .compact: 32
        case .comfortable: 44
        }
    }

    /// Vertical padding inside a row at this density.
    var rowVerticalPadding: CGFloat {
        switch self {
        case .compact: Theme.Spacing.xs
        case .comfortable: Theme.Spacing.sm
        }
    }
}

extension EnvironmentValues {
    @Entry var density: DensityMode = .compact
}

extension View {
    /// Sets the row density for this view subtree.
    func density(_ mode: DensityMode) -> some View {
        environment(\.density, mode)
    }
}
