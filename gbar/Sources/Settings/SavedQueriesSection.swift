import SwiftUI

/// Editor for the user's menu sections: add, rename, retype the GitHub search, reorder
/// (drag), and delete (swipe). Each row writes straight back into `store.savedQueries`,
/// whose `didSet` persists the change. A row with a blank title or query is flagged as
/// incomplete so it's visible it won't produce useful results.
struct SavedQueriesSection: View {
    @Bindable var store: AppStore

    var body: some View {
        Section("Saved Queries") {
            ForEach($store.savedQueries) { $section in
                row($section)
            }
            .onDelete { store.deleteSavedQuery(at: $0) }
            .onMove { store.moveSavedQuery(from: $0, to: $1) }

            Button {
                store.addSavedQuery()
            } label: {
                Label("Add saved query", systemImage: "plus.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.Palette.accent)
        }
    }

    private func row(_ section: Binding<SearchQuery.Section>) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(spacing: Theme.Spacing.sm) {
                TextField("Title", text: section.title)
                    .textFieldStyle(.plain)
                    .font(Theme.Typography.rowTitle)
                if isIncomplete(section.wrappedValue) {
                    Label("Incomplete", systemImage: "exclamationmark.triangle.fill")
                        .labelStyle(.iconOnly)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.pending)
                        .help("Give this query a title and a search to include it.")
                }
            }
            SearchField(placeholder: "is:open is:pr review-requested:@me", text: section.query)
            HStack(spacing: Theme.Spacing.sm) {
                Picker("Tab", selection: section.kind) {
                    Text("Auto").tag(SearchQuery.Section.Kind?.none)
                    Text("PRs").tag(SearchQuery.Section.Kind?.some(.prs))
                    Text("Issues").tag(SearchQuery.Section.Kind?.some(.issues))
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                // "Auto" routes by the query text — show where it lands so the choice is legible.
                if section.wrappedValue.kind == nil {
                    Text("→ \(kindLabel(section.wrappedValue.resolvedKind)) tab")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, Theme.Spacing.xs)
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
