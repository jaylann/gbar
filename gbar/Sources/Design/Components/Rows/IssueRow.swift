import SwiftUI

/// An issue row, driven by the live `SearchIssue` model. Same weight hierarchy as
/// `PRRow`: bold title, dim mono meta, colored state glyph. A trailing author avatar
/// stands in for assignee until that data is wired; `labels` is optional and forward-
/// looking.
struct IssueRow: View {
    let issue: SearchIssue
    var labels: [String] = []
    var isUnseen = false
    var isStarred = false

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
                if let login = issue.user?.login {
                    Avatar(login: login, url: issue.user?.avatarURL.flatMap(URL.init))
                }
                if isUnseen {
                    UnseenDot(isUnseen: true)
                }
            }
        }
    }

    private var metaLine: some View {
        HStack(spacing: Theme.Spacing.xs) {
            StarMarker(isStarred: isStarred)
            Text(issue.repositorySlug)
            Text("#\(issue.number)")
                .font(Theme.Typography.mono)
            ForEach(labels.prefix(2), id: \.self) { label in
                Text(label)
                    .padding(.horizontal, Theme.Spacing.xs)
                    .background(Surface.controlFill, in: Capsule())
            }
            Text("· \(issue.createdAt.compactAgo())")
        }
        .font(Theme.Typography.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}

#if DEBUG
#Preview("IssueRow") {
    VStack(spacing: 2) {
        HoverRow { IssueRow(issue: .previewOpenIssue, labels: ["bug", "ui"], isUnseen: true) }
        HoverRow(isFocused: true) { IssueRow(issue: .previewClosedIssue) }
    }
    .padding(Theme.Spacing.sm)
    .frame(width: 380)
}
#endif
