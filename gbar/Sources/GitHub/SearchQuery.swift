import Foundation

/// The default menu sections, expressed as GitHub search queries. Users can add their own
/// saved queries on top of these (see docs/PRODUCT.md). `@me` resolves to the signed-in user.
enum SearchQuery {
    struct Section: Identifiable, Codable {
        let id: String
        var title: String
        var query: String

        /// Whether this row has a non-blank query worth sending to `/search/issues`.
        /// GitHub rejects an empty `q` with 422, so freshly-added/incomplete rows are
        /// skipped on refresh rather than fetched.
        var isRunnable: Bool {
            !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Baseline sections shipped with v1. Issue tracking, checks, and custom saved queries
    /// build on the same `/search/issues` mechanism — see the roadmap in docs/PRODUCT.md.
    static let defaults: [Section] = [
        Section(id: "review-requested", title: "Review requested", query: "is:open is:pr review-requested:@me"),
        Section(id: "assigned-prs", title: "Assigned PRs", query: "is:open is:pr assignee:@me"),
        Section(id: "created-prs", title: "Your PRs", query: "is:open is:pr author:@me"),
        Section(id: "assigned-issues", title: "Assigned issues", query: "is:open is:issue assignee:@me"),
    ]
}
