import SwiftUI

/// The Queries settings pane: an editor for the menu's saved-search sections. Queries render as
/// compact summary rows — title, the search in mono beneath, and a routing tag — that expand
/// one at a time into an inline editor (title, search, tab routing). Reorder/delete controls
/// reveal on hover, so the resting list stays scannable. Every edit writes straight back into
/// `store.savedQueries`, whose `didSet` persists it.
struct QueriesPane: View {
    @Bindable var store: AppStore

    /// The id of the query currently open for editing; nil = all collapsed.
    @State private var expandedID: String?
    @FocusState private var focusedTitleID: String?
    @FocusState private var queryFieldFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                SectionHeader(
                    title: "Saved queries",
                    count: store.savedQueries.isEmpty ? nil : store.savedQueries.count
                )
                Text("Each query becomes a section in the menu, stacked in this order.")
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
                    VStack(spacing: 2) {
                        ForEach(Array(store.savedQueries.enumerated()), id: \.element.id) { index, section in
                            if section.id == expandedID {
                                queryEditor(index: index)
                            } else {
                                queryRow(index: index, section: section)
                            }
                        }
                    }
                    .padding(.horizontal, Theme.Spacing.md)
                    // Rows are id-keyed, so reorders/deletes glide instead of snapping.
                    .animation(Motion.respecting(reduceMotion, Motion.spring), value: store.savedQueries.map(\.id))
                }

                Button {
                    store.addSavedQuery()
                    // Open the fresh query for editing right away, title field focused.
                    let newID = store.savedQueries.last?.id
                    withAnimation(Motion.respecting(reduceMotion, Motion.spring)) { expandedID = newID }
                    focusedTitleID = newID
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

    // MARK: Collapsed row

    private func queryRow(index: Int, section: SearchQuery.Section) -> some View {
        let count = store.savedQueries.count
        let untitled = section.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return Button {
            withAnimation(Motion.respecting(reduceMotion, Motion.spring)) { expandedID = section.id }
        } label: {
            HoverRow(trailingAccessory: {
                rowControls(index: index, count: count, id: section.id)
            }, content: {
                HStack(spacing: Theme.Spacing.sm) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(untitled ? "Untitled" : section.title)
                            .font(untitled ? Theme.Typography.rowTitle.italic() : Theme.Typography.rowTitle)
                            .foregroundStyle(untitled ? .secondary : .primary)
                        Text(section.query.isEmpty ? "No search yet" : section.query)
                            .font(Theme.Typography.mono)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: Theme.Spacing.sm)
                    if isIncomplete(section) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.pending)
                            .gbTooltip("Give this query a title and a search to include it.")
                            .accessibilityLabel("Incomplete")
                    }
                    TagBadge(kindTag(section))
                }
            })
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Edit \(untitled ? "untitled query" : section.title)")
    }

    /// The routing tag on a collapsed row: the explicit kind, or where Auto resolves to.
    private func kindTag(_ section: SearchQuery.Section) -> String {
        switch section.kind {
        case .prs: "PRs"
        case .issues: "Issues"
        case .none: "Auto → \(kindLabel(section.resolvedKind))"
        }
    }

    private func rowControls(index: Int, count: Int, id: String) -> some View {
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
                deleteQuery(index: index, id: id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(GBButtonStyle(variant: .icon))
            .gbTooltip("Delete query")
            .accessibilityLabel("Delete query")
        }
    }

    // MARK: Expanded editor

    @ViewBuilder
    private func queryEditor(index: Int) -> some View {
        // Guard the index-based binding: a delete can race one render ahead of `expandedID`.
        if index < store.savedQueries.count {
            let section = $store.savedQueries[index]
            let value = section.wrappedValue
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                TextField("Title", text: section.title)
                    .modifier(SettingsFieldStyle())
                    .font(Theme.Typography.rowTitle)
                    .focused($focusedTitleID, equals: value.id)
                SearchField(
                    placeholder: "is:open is:pr review-requested:@me",
                    text: section.query,
                    focus: $queryFieldFocused
                )
                if queryFieldFocused {
                    suggestionList(query: section.query)
                }
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
                if isIncomplete(value) {
                    ValidationHint(message: "Needs a title and a search to appear in the menu.")
                }
                editorFooter(index: index, id: value.id)
            }
            .padding(Theme.Spacing.sm)
            .background(Surface.controlFill, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        }
    }

    /// GitHub-style qualifier autocomplete under the query field: tap a row to complete the
    /// token being typed. Complete qualifiers append a space; open-ended ones (`label:` …)
    /// leave the caret ready for a value. Focus returns to the field after each insert.
    @ViewBuilder
    private func suggestionList(query: Binding<String>) -> some View {
        let matches = QuerySuggestions.matches(for: query.wrappedValue)
        if !matches.isEmpty {
            VStack(spacing: 0) {
                ForEach(matches) { suggestion in
                    Button {
                        query.wrappedValue = QuerySuggestions.applying(suggestion, to: query.wrappedValue)
                        queryFieldFocused = true
                    } label: {
                        HStack(spacing: Theme.Spacing.sm) {
                            Text(suggestion.text)
                                .font(Theme.Typography.mono)
                            Spacer(minLength: Theme.Spacing.sm)
                            Text(suggestion.detail)
                                .font(Theme.Typography.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, Theme.Spacing.sm)
                        .frame(height: 24)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(SuggestionRowStyle())
                }
            }
            .padding(Theme.Spacing.xs)
            .background(Surface.canvas, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                    .strokeBorder(Surface.hairline, lineWidth: 1)
            }
            .animation(Motion.respecting(reduceMotion, Motion.fade), value: matches)
        }
    }

    private func editorFooter(index: Int, id: String) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            Button("Done") {
                withAnimation(Motion.respecting(reduceMotion, Motion.spring)) { expandedID = nil }
            }
            .buttonStyle(GBButtonStyle(variant: .secondary))
            Spacer(minLength: 0)
            Button(role: .destructive) {
                deleteQuery(index: index, id: id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(GBButtonStyle(variant: .icon))
            .gbTooltip("Delete query")
            .accessibilityLabel("Delete query")
        }
    }

    private func deleteQuery(index: Int, id: String) {
        if expandedID == id { expandedID = nil }
        store.deleteSavedQuery(at: IndexSet(integer: index))
    }

    // MARK: Kind plumbing

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

/// Hover-highlighted suggestion row: quiet by default, `rowHover` fill under the pointer.
private struct SuggestionRowStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                isHovering || configuration.isPressed ? Surface.rowHover : .clear,
                in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
            )
            .onHover { isHovering = $0 }
    }
}

#if DEBUG
#Preview("QueriesPane") {
    QueriesPane(store: AppStore())
        .frame(width: 500, height: 560)
        .background(Surface.canvas)
}
#endif
