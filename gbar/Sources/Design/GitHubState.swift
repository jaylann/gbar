import SwiftUI

/// The display state of a PR or issue — the single place color and shape are paired.
/// GitHub's Primer principle is that state is *never* signalled by color alone, so
/// each case carries both a `color` (from `Theme.Palette`) and an SF Symbol `shape`.
/// `StateBadge`, `PRRow`, and `IssueRow` all resolve their look through this.
enum GitHubState {
    case open
    case draft
    case merged
    case closed
    /// An issue closed as completed (Primer renders this purple, like a merge).
    case done

    /// Derive the state from a `/search/issues` item. PRs distinguish merged/draft/
    /// closed; issues collapse to open or done (closed-completed).
    init(issue: SearchIssue) {
        if issue.isPullRequest {
            if issue.pullRequest?.mergedAt != nil {
                self = .merged
            } else if issue.draft == true {
                self = .draft
            } else {
                self = issue.state == "closed" ? .closed : .open
            }
        } else {
            self = issue.state == "closed" ? .done : .open
        }
    }

    var color: Color {
        switch self {
        case .open: Theme.Palette.open
        case .draft: Theme.Palette.draft
        case .done,
             .merged: Theme.Palette.merged
        case .closed: Theme.Palette.closed
        }
    }

    /// SF Symbol that carries the state's meaning without relying on color.
    var symbol: String {
        switch self {
        case .open: "smallcircle.filled.circle"
        case .draft: "circle.dotted"
        case .merged: "arrow.triangle.merge"
        case .closed: "xmark.circle"
        case .done: "checkmark.circle"
        }
    }

    var label: String {
        switch self {
        case .open: "Open"
        case .draft: "Draft"
        case .merged: "Merged"
        case .closed: "Closed"
        case .done: "Closed"
        }
    }
}
