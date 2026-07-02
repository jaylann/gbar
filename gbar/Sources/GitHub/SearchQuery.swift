import Foundation

/// The default menu sections, expressed as GitHub search queries. Users can add their own
/// saved queries on top of these (see docs/PRODUCT.md). `@me` resolves to the signed-in user.
enum SearchQuery {
    struct Section: Identifiable, Codable {
        /// Which top-level menu tab a section's results belong to. PRs and issues are both
        /// `/search/issues`-driven, so a section is routed as a whole by its kind rather than
        /// splitting individual items across tabs.
        enum Kind: String, Codable {
            case prs
            case issues
        }

        let id: String
        var title: String
        var query: String
        /// User-chosen routing. `nil` means "auto" — fall back to `inferredKind`.
        var kind: Kind?

        /// Whether this row has a non-blank query worth sending to `/search/issues`.
        /// GitHub rejects an empty `q` with 422, so freshly-added/incomplete rows are
        /// skipped on refresh rather than fetched.
        var isRunnable: Bool {
            !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        /// Kind guessed from the query text. Tokenized (not substring) so a negated
        /// `-is:issue` doesn't read as an issue query; `is:pr` wins over `is:issue` if both
        /// appear, and everything else (including bare queries) defaults to PRs.
        var inferredKind: Kind {
            let tokens = query.lowercased().split(whereSeparator: \.isWhitespace)
            if tokens.contains("is:pr") { return .prs }
            if tokens.contains("is:issue") { return .issues }
            return .prs
        }

        /// The kind to route by: the explicit choice if set, otherwise the inferred one.
        var resolvedKind: Kind {
            kind ?? inferredKind
        }
    }

    /// Baseline sections shipped with v1. Issue tracking, checks, and custom saved queries
    /// build on the same `/search/issues` mechanism — see the roadmap in docs/PRODUCT.md.
    static let defaults: [Section] = [
        Section(
            id: "review-requested",
            title: "Review requested",
            query: "is:open is:pr review-requested:@me",
            kind: .prs
        ),
        Section(id: "assigned-prs", title: "Assigned PRs", query: "is:open is:pr assignee:@me", kind: .prs),
        Section(id: "created-prs", title: "Your PRs", query: "is:open is:pr author:@me", kind: .prs),
        Section(id: "assigned-issues", title: "Assigned issues", query: "is:open is:issue assignee:@me", kind: .issues),
    ]
}
