import SwiftUI

/// A small amber star shown on a row whose repository the viewer has starred. Read-only — it's
/// a cross-cutting signal (surfaced from `/user/starred`), not a toggle. Renders nothing when
/// the repo isn't starred, so a row never reserves an empty slot for it.
struct StarMarker: View {
    let isStarred: Bool

    var body: some View {
        if isStarred {
            Image(systemName: "star.fill")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.accent)
                .accessibilityLabel("Starred repository")
        }
    }
}

#if DEBUG
#Preview("StarMarker") {
    HStack(spacing: Theme.Spacing.sm) {
        StarMarker(isStarred: true)
        Text("owner/repo").font(Theme.Typography.caption).foregroundStyle(.secondary)
    }
    .padding(Theme.Spacing.md)
}
#endif
