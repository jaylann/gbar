import Foundation

// MARK: - Saved queries

extension AppStore {
    /// Append a fresh, empty saved query for the user to fill in. The UUID id keeps it
    /// distinct from the baseline sections (so badge/actionable semantics are unaffected).
    func addSavedQuery() {
        savedQueries.append(SearchQuery.Section(id: UUID().uuidString, title: "", query: "", kind: nil))
    }

    func deleteSavedQuery(at offsets: IndexSet) {
        savedQueries.remove(atOffsets: offsets)
    }

    func moveSavedQuery(from source: IndexSet, to destination: Int) {
        savedQueries.move(fromOffsets: source, toOffset: destination)
    }
}
