import SwiftUI

/// The Watchlist settings pane: the curated set of `owner/name` repos whose GitHub Actions runs
/// and releases feed the menu's Actions and Releases tabs. Repos are added through a single
/// validated input up top (invalid or duplicate slugs get inline feedback, never appended);
/// existing entries render as read-only rows with hover-revealed reorder/delete controls.
/// Deliberately the *only* scope for those tabs (not the starred set), so the per-repo request
/// fan-out stays bounded.
struct WatchlistPane: View {
    @Bindable var store: AppStore

    @State private var newRepo = ""
    /// Inline feedback for the add field — set on an invalid/duplicate submit, cleared on edit.
    @State private var addHint: String?
    @FocusState private var addFieldFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Watchlist entries with a stable identity for animated moves. Slugs are usually unique
    /// (the add path de-dupes), but legacy data may repeat — an occurrence suffix keeps the
    /// `ForEach` ids distinct either way.
    private var keyedEntries: [(key: String, index: Int, entry: String)] {
        var counts: [String: Int] = [:]
        return store.watchlist.enumerated().map { index, entry in
            let occurrence = counts[entry, default: 0]
            counts[entry] = occurrence + 1
            return ("\(entry)#\(occurrence)", index, entry)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                SectionHeader(
                    title: "Watched repos",
                    count: store.watchlist.isEmpty ? nil : store.watchlist.count
                )
                Text("gbar follows each repo's Actions runs and releases — they fill the Actions and Releases tabs.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Theme.Spacing.md)

                addRow
                    .padding(.horizontal, Theme.Spacing.md)
                    .padding(.top, Theme.Spacing.xs)

                if store.watchlist.isEmpty {
                    EmptyStateView(
                        intent: .neutral,
                        title: "No watched repos",
                        message: "Add a repo above to follow its Actions runs and releases."
                    )
                } else {
                    let entries = keyedEntries
                    VStack(spacing: 2) {
                        ForEach(entries, id: \.key) { item in
                            repoRow(index: item.index, entry: item.entry)
                        }
                    }
                    .padding(.horizontal, Theme.Spacing.md)
                    // Rows are identity-keyed, so reorders/deletes glide instead of snapping.
                    .animation(Motion.respecting(reduceMotion, Motion.spring), value: entries.map(\.key))
                }
            }
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, Theme.Spacing.md)
        }
    }

    // MARK: Add

    private var addRow: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(spacing: Theme.Spacing.sm) {
                TextField("owner/name", text: $newRepo)
                    .modifier(SettingsFieldStyle())
                    .font(Theme.Typography.mono)
                    .focused($addFieldFocused)
                    .onSubmit(addRepo)
                    .onChange(of: newRepo) { addHint = nil }
                Button("Add", action: addRepo)
                    .buttonStyle(GBButtonStyle(variant: .secondary))
                    .disabled(newRepo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let addHint {
                ValidationHint(message: addHint)
            }
        }
    }

    private func addRepo() {
        let input = newRepo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }
        guard let slug = AppStore.normalizedSlug(input) else {
            addHint = "Enter a repo as owner/name."
            return
        }
        guard store.addWatchRepo(slug) else {
            addHint = "Already watching \(slug)."
            return
        }
        newRepo = ""
        addHint = nil
        // Keep focus so several repos can be added back to back.
        addFieldFocused = true
    }

    // MARK: Rows

    private func repoRow(index: Int, entry: String) -> some View {
        let count = store.watchlist.count
        let isValid = AppStore.normalizedSlug(entry) != nil
        return HoverRow(trailingAccessory: {
            rowControls(index: index, count: count)
        }, content: {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: "shippingbox")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)
                Text(entry.isEmpty ? "(blank)" : entry)
                    .font(Theme.Typography.mono)
                    .foregroundStyle(isValid ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                // Legacy persisted entries can predate the validated add field — keep them
                // flagged (and deletable) rather than silently skipped.
                if !isValid {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.pending)
                        .gbTooltip("Not a valid owner/name — this entry is skipped.")
                        .accessibilityLabel("Invalid repo")
                }
                Spacer(minLength: 0)
            }
        })
    }

    private func rowControls(index: Int, count: Int) -> some View {
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
        .frame(width: Theme.Layout.settingsWidth, height: Theme.Layout.settingsHeight)
        .background(Surface.canvas)
}
#endif
