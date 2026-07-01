import SwiftUI

/// Interaction surfaces layered on top of the popover's system material. Kept as a
/// small ladder — canvas is the material itself; hover/selection are subtle fills so
/// a scanned list stays quiet and only the pointed-at row lifts. Deliberately
/// tint-neutral (built on `Color.primary`/`link`) so it reads on both appearances.
enum Surface {
    /// The popover's opaque base. The `MenuBarExtra(.window)` material is very
    /// translucent, so the desktop bleeds through and muddies every color — this solid
    /// (very slightly lifted in dark, so it reads as foreground over the menu bar)
    /// makes the palette render true, like the gallery.
    static let canvas = Color(light: "FFFFFF", dark: "1F2023")

    /// Fill under the row the pointer is over. Barely-there so scanning isn't noisy.
    static let rowHover = Color.primary.opacity(0.06)

    /// Fill under the keyboard-focused / selected row — link-tinted so it reads as
    /// "this is where the keyboard is", distinct from a mere hover.
    static let selection = Theme.Palette.link.opacity(0.14)

    /// The focus ring stroke around the keyboard-focused row.
    static let focusRing = Theme.Palette.link.opacity(0.55)

    /// Hairline separators. Use sparingly — prefer whitespace + section headers.
    static let hairline = Color.primary.opacity(0.10)

    /// Resting fill for secondary/ghost controls and chips before interaction.
    static let controlFill = Color.primary.opacity(0.06)

    /// Fill for a control while the pointer is over it.
    static let controlHover = Color.primary.opacity(0.10)

    /// Fill for a control while pressed.
    static let controlPressed = Color.primary.opacity(0.16)
}
