import SwiftUI

/// A circular user/org avatar. Loads from a URL, shimmers while loading, and falls
/// back to the login's initial on a color derived deterministically from the login —
/// so a missing image is still identifiable and stable across refreshes.
struct Avatar: View {
    let login: String
    var url: URL?
    var size: Size = .small

    enum Size {
        case small
        case medium
        case large

        var diameter: CGFloat {
            switch self {
            case .small: 20
            case .medium: 28
            case .large: 32
            }
        }
    }

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case let .success(image):
                        image.resizable().scaledToFill()
                    case .empty:
                        fallback.redacted(reason: .placeholder)
                    case .failure:
                        fallback
                    @unknown default:
                        fallback
                    }
                }
            } else {
                fallback
            }
        }
        .frame(width: size.diameter, height: size.diameter)
        .clipShape(Circle())
    }

    private var fallback: some View {
        generatedColor
            .overlay {
                Text(initial)
                    .font(.system(size: size.diameter * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
            }
    }

    private var initial: String {
        guard let first = login.first else { return "?" }
        return String(first).uppercased()
    }

    /// Stable hue from the login so the same user always gets the same swatch.
    private var generatedColor: Color {
        let hash = login.unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) &+ $0 &+ $1.value }
        let hue = Double(hash % 360) / 360
        return Color(hue: hue, saturation: 0.55, brightness: 0.65)
    }
}

#if DEBUG
#Preview("Avatar") {
    HStack(spacing: Theme.Spacing.md) {
        Avatar(login: "jaylann", size: .small)
        Avatar(login: "octocat", size: .medium)
        Avatar(login: "github", size: .large)
    }
    .padding(Theme.Spacing.xl)
}
#endif
