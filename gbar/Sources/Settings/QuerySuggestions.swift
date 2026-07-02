import SwiftUI

/// GitHub search-qualifier autocomplete for the saved-query editor. A curated catalog of the
/// qualifiers that matter in a PR/issue menu (the same ones github.com suggests), matched
/// against the token being typed. Pure value logic — the view lives in `QueriesPane`.
struct QuerySuggestion: Identifiable, Equatable {
    /// The qualifier to insert, e.g. `is:open` or the open-ended `label:`.
    let text: String
    /// Short human explanation shown next to it.
    let detail: String

    var id: String {
        text
    }

    /// Open-ended qualifiers (trailing `:`) still need a value typed after insertion.
    var needsValue: Bool {
        text.hasSuffix(":")
    }
}

enum QuerySuggestions {
    static let catalog: [QuerySuggestion] = [
        .init(text: "is:open", detail: "Open items"),
        .init(text: "is:closed", detail: "Closed items"),
        .init(text: "is:pr", detail: "Pull requests only"),
        .init(text: "is:issue", detail: "Issues only"),
        .init(text: "is:merged", detail: "Merged pull requests"),
        .init(text: "is:draft", detail: "Draft pull requests"),
        .init(text: "author:@me", detail: "Created by you"),
        .init(text: "assignee:@me", detail: "Assigned to you"),
        .init(text: "review-requested:@me", detail: "Your review is requested"),
        .init(text: "mentions:@me", detail: "Mentions you"),
        .init(text: "involves:@me", detail: "You're involved"),
        .init(text: "review:approved", detail: "Approved pull requests"),
        .init(text: "review:changes_requested", detail: "Changes requested"),
        .init(text: "draft:false", detail: "Ready for review"),
        .init(text: "repo:", detail: "Limit to a repo (owner/name)"),
        .init(text: "org:", detail: "Limit to an organization"),
        .init(text: "user:", detail: "Limit to a user's repos"),
        .init(text: "label:", detail: "Filter by label"),
        .init(text: "milestone:", detail: "Filter by milestone"),
        .init(text: "base:", detail: "PR base branch"),
        .init(text: "head:", detail: "PR head branch"),
        .init(text: "no:assignee", detail: "Unassigned items"),
        .init(text: "sort:updated-desc", detail: "Recently updated first"),
        .init(text: "sort:created-desc", detail: "Newest first"),
    ]

    static let maxShown = 5

    /// Suggestions for the token currently being typed (the text after the last space).
    /// An empty token offers the most common qualifiers; qualifiers already present in the
    /// query are never re-suggested. Matches by prefix first, then substring (so "me" finds
    /// `author:@me`), capped at `maxShown`.
    static func matches(for query: String) -> [QuerySuggestion] {
        let tokens = query.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        let current = tokens.last ?? ""
        let earlier = Set(tokens.dropLast())
        let pool = catalog.filter { !earlier.contains($0.text) }
        guard !current.isEmpty else { return Array(pool.prefix(maxShown)) }
        let lowered = current.lowercased()
        let prefixed = pool.filter { $0.text.hasPrefix(lowered) && $0.text != lowered }
        let contained = pool.filter { !$0.text.hasPrefix(lowered) && $0.text.contains(lowered) }
        return Array((prefixed + contained).prefix(maxShown))
    }

    /// Replace the token being typed with the chosen suggestion. Complete qualifiers get a
    /// trailing space to move on to the next term; open-ended ones leave the caret after `:`.
    static func applying(_ suggestion: QuerySuggestion, to query: String) -> String {
        var tokens = query.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        if tokens.isEmpty { tokens = [""] }
        tokens[tokens.count - 1] = suggestion.text
        let joined = tokens.joined(separator: " ")
        return suggestion.needsValue ? joined : joined + " "
    }
}
