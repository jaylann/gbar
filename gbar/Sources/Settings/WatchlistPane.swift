import SwiftUI

/// The Watchlist settings pane: the curated set of `owner/name` repos whose GitHub Actions runs
/// and releases feed the menu's Actions and Releases tabs. Each repo is a small card — edit the
/// slug, reorder, or delete it. Every edit writes straight back into `store.watchlist`, whose
/// `didSet` persists it. Deliberately the *only* scope for those tabs (not the starred set), so
/// the per-repo request fan-out stays bounded.
struct WatchlistPane: View {
    @Bindable var store: AppStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                SectionHeader(
                    title: "Watched repos",
                    count: store.watchlist.isEmpty ? nil : store.watchlist.count
                )
                Text("Each repo (owner/name) feeds the Actions and Releases tabs. Blank entries are skipped.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Theme.Spacing.md)

                if store.watchlist.isEmpty {
                    EmptyStateView(
                        intent: .neutral,
                        title: "No watched repos",
                        message: "Add a repo to follow its Actions runs and releases."
                    )
                } else {
                    ForEach(Array(store.watchlist.enumerated()), id: \.offset) { index, _ in
                        repoCard(index: index)
                    }
                    .padding(.horizontal, Theme.Spacing.md)
                }

                Button {
                    store.addWatchRepo()
                } label: {
                    Label("Add repo", systemImage: "plus.circle")
                }
                .buttonStyle(GBButtonStyle(variant: .ghost))
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.top, Theme.Spacing.xs)
            }
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, Theme.Spacing.md)
        }
    }

    private func repoCard(index: Int) -> some View {
        let entry = $store.watchlist[index]
        let count = store.watchlist.count
        let isValid = AppStore.normalizedSlug(entry.wrappedValue) != nil
        return HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "shippingbox")
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)
            TextField("owner/name", text: entry)
                .textFieldStyle(.plain)
                .font(Theme.Typography.mono)
            if !isValid {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.pending)
                    .gbTooltip("Enter a repo as owner/name.")
                    .accessibilityLabel("Invalid repo")
            }
            Spacer(minLength: Theme.Spacing.sm)
            reorderControls(index: index, count: count)
        }
        .padding(Theme.Spacing.sm)
        .background(Surface.controlFill, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
    }

    private func reorderControls(index: Int, count: Int) -> some View {
        HStack(spacing: 2) {
            Button {
                store.moveWatchRepo(from: IndexSet(integer: index), to: index - 1)
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(GBButtonStyle(variant: .icon))
            .disabled(index == 0)
            .gbTooltip("Move up")
            .accessibilityLabel("Move up")

            Button {
                store.moveWatchRepo(from: IndexSet(integer: index), to: index + 2)
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(GBButtonStyle(variant: .icon))
            .disabled(index >= count - 1)
            .gbTooltip("Move down")
            .accessibilityLabel("Move down")

            Button(role: .destructive) {
                store.deleteWatchRepo(at: IndexSet(integer: index))
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(GBButtonStyle(variant: .icon))
            .gbTooltip("Remove repo")
            .accessibilityLabel("Remove repo")
        }
    }
}

#if DEBUG
#Preview("WatchlistPane") {
    WatchlistPane(store: AppStore())
        .frame(width: 500, height: 560)
        .background(Surface.canvas)
}
#endif
