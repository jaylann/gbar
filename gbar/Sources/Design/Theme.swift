import AppKit
import SwiftUI

/// SwiftUI `Color` from a hex string, e.g. `"E8843C"` or `"#E8843C"`.
///
/// Accepts an optional leading `#`, and 6-digit RGB or 8-digit RGBA. Malformed
/// input falls back to opaque black so a bad literal never crashes rendering.
extension Color {
    init(hex: String) {
        let cleaned = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)

        let r, g, b, a: Double
        switch cleaned.count {
        case 8: // RRGGBBAA
            r = Double((value >> 24) & 0xFF) / 255
            g = Double((value >> 16) & 0xFF) / 255
            b = Double((value >> 8) & 0xFF) / 255
            a = Double(value & 0xFF) / 255
        default: // RRGGBB (or malformed → black)
            r = Double((value >> 16) & 0xFF) / 255
            g = Double((value >> 8) & 0xFF) / 255
            b = Double(value & 0xFF) / 255
            a = 1
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }

    /// Appearance-adaptive color from two hex strings: a deep tone for light mode,
    /// a slightly lifted (still rich) tone for dark mode so it stays legible on the
    /// dark popover material. Avoids stock system colors, which read too bright.
    init(light: String, dark: String) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(Color(hex: isDark ? dark : light))
        })
    }
}

/// Design token layer: the single source of truth for color, spacing, radii, and
/// type. Functional dev-tool look — no gradients, no decoration. State colors follow
/// GitHub's Primer semantics as deep/rich appearance-adaptive tones; only the amber
/// brand accent is a fixed hex. Interaction surfaces live in `Surface`, motion in
/// `Motion`, row density in `DensityMode`.
enum Theme {
    // MARK: - Palette

    enum Palette {
        /// gbar brand accent — the one fixed brand color.
        static let accent = Color(hex: "E8843C")

        // GitHub-convention issue/PR state colors, as deep/rich appearance-adaptive
        // tones (Primer-style) rather than the too-bright stock system colors.
        static let open = Color(light: "1A7F37", dark: "3FB950")
        static let merged = Color(light: "8250DF", dark: "A371F7")
        static let closed = Color(light: "CF222E", dark: "F85149")
        static let draft = Color(light: "6E7781", dark: "8B949E")
        static let pending = Color(light: "9A6700", dark: "D29922")

        /// Interaction blue — links, keyboard focus, the unseen dot. Kept distinct
        /// from the amber brand accent so "actionable" and "brand" never collide.
        static let link = Color(light: "0969DA", dark: "2F81F7")
    }

    // MARK: - Spacing (8pt grid)

    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
    }

    // MARK: - Corner radii

    enum Radius {
        static let sm: CGFloat = 4
        static let md: CGFloat = 8
    }

    // MARK: - Typography

    enum Typography {
        /// Uppercase section headers above a group of rows.
        static let sectionLabel = Font.system(size: 11, weight: .semibold)
        /// Primary text of a PR/issue row.
        static let rowTitle = Font.system(size: 13, weight: .semibold)
        /// Secondary metadata (repo slug, number, author).
        static let caption = Font.system(size: 11)
        /// Code-shaped text: `#123`, branch names, SHAs, durations. Monospaced so it
        /// doesn't jitter when values change on refresh.
        static let mono = Font.system(size: 11, design: .monospaced)
    }
}

#if DEBUG
#Preview("Theme tokens") {
    let states: [(String, Color)] = [
        ("accent", Theme.Palette.accent),
        ("open", Theme.Palette.open),
        ("merged", Theme.Palette.merged),
        ("closed", Theme.Palette.closed),
        ("draft", Theme.Palette.draft),
        ("pending", Theme.Palette.pending),
        ("link", Theme.Palette.link),
    ]
    let spacings: [(String, CGFloat)] = [
        ("xs", Theme.Spacing.xs),
        ("sm", Theme.Spacing.sm),
        ("md", Theme.Spacing.md),
        ("lg", Theme.Spacing.lg),
        ("xl", Theme.Spacing.xl),
    ]

    return VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("PALETTE").font(Theme.Typography.sectionLabel)
            HStack(spacing: Theme.Spacing.sm) {
                ForEach(states, id: \.0) { name, color in
                    VStack(spacing: Theme.Spacing.xs) {
                        RoundedRectangle(cornerRadius: Theme.Radius.sm)
                            .fill(color)
                            .frame(width: 44, height: 44)
                        Text(name).font(Theme.Typography.caption)
                    }
                }
            }
        }

        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("SPACING").font(Theme.Typography.sectionLabel)
            ForEach(spacings, id: \.0) { name, value in
                HStack(spacing: Theme.Spacing.sm) {
                    Text(name).font(Theme.Typography.caption).frame(width: 24, alignment: .leading)
                    Rectangle()
                        .fill(Theme.Palette.accent)
                        .frame(width: value, height: 12)
                    Text("\(Int(value))pt").font(Theme.Typography.caption).foregroundStyle(.secondary)
                }
            }
        }

        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text("TYPOGRAPHY").font(Theme.Typography.sectionLabel)
            Text("Row title").font(Theme.Typography.rowTitle)
            Text("Caption metadata").font(Theme.Typography.caption).foregroundStyle(.secondary)
            Text("feature/mono-123").font(Theme.Typography.mono).foregroundStyle(.secondary)
        }
    }
    .padding(Theme.Spacing.xl)
    .frame(width: 420)
}
#endif
