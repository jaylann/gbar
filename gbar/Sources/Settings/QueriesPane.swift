import SwiftUI

/// The Queries settings pane: an editor for the menu's saved-search sections. Each query is a
/// self-contained card — rename it, edit the GitHub search, pick which tab it routes to, and
/// reorder or delete it with explicit controls (clearer on macOS than hidden drag/swipe).
/// Every edit writes straight back into `store.savedQueries`, whose `didSet` persists it.
struct QueriesPane: View {
    @Bindable var store: AppStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                SectionHeader(
                    title: "Saved queries",
                    count: store.savedQueries.isEmpty ? nil : store.savedQueries.count
                )
                Text("Each query becomes a section in the menu. Reorder to set how they stack; blank ones are skipped.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Theme.Spacing.md)

                if store.savedQueries.isEmpty {
                    EmptyStateView(
                        intent: .neutral,
                        title: "No saved queries",
                        message: "Add a search to give the menu a section of its own."
                    )
                } else {
                    ForEach(Array(store.savedQueries.enumerated()), id: \.element.id) { index, _ in
                        queryCard(index: index)
                    }
                    .padding(.horizontal, Theme.Spacing.md)
                }

                Button {
                    store.addSavedQuery()
                } label: {
                    Label("Add saved query", systemImage: "plus.circle")
                }
                .buttonStyle(GBButtonStyle(variant: .ghost))
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.top, Theme.Spacing.xs)
            }
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, Theme.Spacing.md)
        }
    }

    private func queryCard(index: Int) -> some View {
        let section = $store.savedQueries[index]
        let value = section.wrappedValue
        let count = store.savedQueries.count
        return VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(spacing: Theme.Spacing.sm) {
                TextField("Title", text: section.title)
                    .textFieldStyle(.plain)
                    .font(Theme.Typography.rowTitle)
                if isIncomplete(value) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.pending)
                        .gbTooltip("Give this query a title and a search to include it.")
                        .accessibilityLabel("Incomplete")
                }
                Spacer(minLength: Theme.Spacing.sm)
                reorderControls(index: index, count: count)
            }
            SearchField(placeholder: "is:open is:pr review-requested:@me", text: section.query)
            HStack(spacing: Theme.Spacing.sm) {
                GBSegmentedControl(segments: kindSegments, selection: kindBinding(section))
                    .frame(width: 210)
                // "Auto" routes by the query text — show where it lands so the choice is legible.
                if value.kind == nil {
                    Text("→ \(kindLabel(value.resolvedKind)) tab")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(Theme.Spacing.sm)
        .background(Surface.controlFill, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
    }

    private func reorderControls(index: Int, count: Int) -> some View {
        HStack(spacing: 2) {
            Button {
                store.moveSavedQuery(from: IndexSet(integer: index), to: index - 1)
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(GBButtonStyle(variant: .icon))
            .disabled(index == 0)
            .gbTooltip("Move up")
            .accessibilityLabel("Move up")

            Button {
                store.moveSavedQuery(from: IndexSet(integer: index), to: index + 2)
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(GBButtonStyle(variant: .icon))
            .disabled(index >= count - 1)
            .gbTooltip("Move down")
            .accessibilityLabel("Move down")

            Button(role: .destructive) {
                store.deleteSavedQuery(at: IndexSet(integer: index))
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(GBButtonStyle(variant: .icon))
            .gbTooltip("Delete query")
            .accessibilityLabel("Delete query")
        }
    }

    private var kindSegments: [GBSegmentedControl<String>.Segment] {
        [
            .init(tag: "auto", title: "Auto"),
            .init(tag: "prs", title: "PRs"),
            .init(tag: "issues", title: "Issues"),
        ]
    }

    /// Bridges the segmented control's `String` tag to the section's optional `Kind`
    /// (`nil` = Auto), so an on-brand segmented control drives the same routing the picker did.
    private func kindBinding(_ section: Binding<SearchQuery.Section>) -> Binding<String> {
        Binding(
            get: {
                switch section.wrappedValue.kind {
                case .none: "auto"
                case .prs: "prs"
                case .issues: "issues"
                }
            },
            set: { tag in
                section.wrappedValue.kind = switch tag {
                case "prs": .prs
                case "issues": .issues
                default: nil
                }
            }
        )
    }

    private func kindLabel(_ kind: SearchQuery.Section.Kind) -> String {
        switch kind {
        case .prs: "PRs"
        case .issues: "Issues"
        }
    }

    /// A saved query needs both a title and a query to be useful; whitespace-only counts
    /// as empty. Flagged rather than blocked so the user can fill it in at their own pace.
    private func isIncomplete(_ section: SearchQuery.Section) -> Bool {
        section.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || section.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

#if DEBUG
#Preview("QueriesPane") {
    QueriesPane(store: AppStore())
        .frame(width: 500, height: 560)
        .background(Surface.canvas)
}
#endif
