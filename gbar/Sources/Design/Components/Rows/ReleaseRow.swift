import SwiftUI

/// A release row — a "what shipped" digest entry for a watched repo. Tag/version in mono (like a
/// branch name), a prerelease pill when relevant, and a shipped-age meta line. Driven by a local
/// display model so the view stays free of the wire type.
struct ReleaseRow: View {
    struct Model: Identifiable {
        let id: String
        let repo: String
        /// The release's human title, falling back to the tag when the name is blank.
        let title: String
        let tag: String
        let date: Date
        var isPrerelease = false
    }

    let model: Model

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.sm) {
            Image(systemName: "shippingbox.fill")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.merged)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Theme.Spacing.xs) {
                    Text(model.title)
                        .font(Theme.Typography.rowTitle)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if model.isPrerelease {
                        Text("pre-release")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, Theme.Spacing.xs)
                            .background(Surface.controlFill, in: Capsule())
                    }
                }
                metaLine
            }

            Spacer(minLength: Theme.Spacing.sm)
        }
    }

    private var metaLine: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Text(model.repo).font(Theme.Typography.mono)
            Text("· \(model.tag)")
                .font(Theme.Typography.mono)
                .foregroundStyle(Theme.Palette.link)
            Text("· \(model.date.compactAgo())")
        }
        .font(Theme.Typography.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}

#if DEBUG
#Preview("ReleaseRow") {
    VStack(spacing: 2) {
        HoverRow {
            ReleaseRow(model: .init(
                id: "1",
                repo: "jaylann/gbar",
                title: "v1.2.0 — Inbox & quick actions",
                tag: "v1.2.0",
                date: Date(timeIntervalSinceNow: -7200)
            ))
        }
        HoverRow(isFocused: true) {
            ReleaseRow(model: .init(
                id: "2",
                repo: "jaylann/gbar",
                title: "v1.3.0-beta.1",
                tag: "v1.3.0-beta.1",
                date: Date(timeIntervalSinceNow: -86400),
                isPrerelease: true
            ))
        }
    }
    .padding(Theme.Spacing.sm)
    .frame(width: 400)
}
#endif
