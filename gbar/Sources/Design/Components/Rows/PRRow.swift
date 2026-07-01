import SwiftUI

/// A pull-request row, driven by the live `SearchIssue` model. Mimestream's weight
/// hierarchy: the title is bold and central; repo · number · author · age recede into
/// a dim mono meta line; only the state badge and CI dot carry color. CI status, diff
/// stats, and the unseen flag are optional — they light up when that data is wired,
/// and the row already has a home for them.
struct PRRow: View {
    let issue: SearchIssue
    var ci: CIStatus?
    var additions: Int?
    var deletions: Int?
    var isUnseen = false

    private var state: GitHubState {
        GitHubState(issue: issue)
    }

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.sm) {
            StateBadge(state: state, size: .small)

            VStack(alignment: .leading, spacing: 2) {
                Text(issue.title)
                    .font(Theme.Typography.rowTitle)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                metaLine
            }

            Spacer(minLength: Theme.Spacing.sm)

            HStack(spacing: Theme.Spacing.sm) {
                if let additions, let deletions {
                    DiffStat(additions: additions, deletions: deletions)
                }
                if let ci {
                    CIStatusIndicator(status: ci)
                }
                if let user = issue.user {
                    Avatar(login: user.login, url: user.avatarURL.flatMap(URL.init))
                }
                // Only occupy trailing space when actually unseen, so seen rows sit flush with
                // the leading padding rather than reserving an empty dot slot.
                if isUnseen {
                    UnseenDot(isUnseen: true)
                }
            }
        }
    }

    private var metaLine: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Text(issue.repositorySlug)
            Text("#\(issue.number)")
                .font(Theme.Typography.mono)
            if let login = issue.user?.login {
                Text("· \(login)")
            }
            Text("· \(issue.createdAt.compactAgo())")
        }
        .font(Theme.Typography.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}

#if DEBUG
#Preview("PRRow") {
    VStack(spacing: 2) {
        HoverRow { PRRow(issue: .previewOpenPR, ci: .success, additions: 42, deletions: 7, isUnseen: true) }
        HoverRow { PRRow(issue: .previewDraftPR, ci: .pending) }
        HoverRow(isFocused: true) { PRRow(issue: .previewMergedPR, additions: 3, deletions: 0) }
    }
    .padding(Theme.Spacing.sm)
    .frame(width: 380)
}
#endif
