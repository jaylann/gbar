#if DEBUG
import Foundation

/// Sample data for component previews only — compiled out of release builds. Uses the
/// synthesized memberwise initializers of the live models so previews exercise the
/// real types, not stand-ins.
extension GitHubUser {
    static let previewMe = GitHubUser(login: "jaylann", avatarURL: nil)
    static let previewOctocat = GitHubUser(login: "octocat", avatarURL: nil)
}

extension SearchIssue {
    static let previewOpenPR = SearchIssue(
        id: 1,
        number: 482,
        title: "Add device-flow token refresh with Keychain persistence",
        htmlURL: "https://github.com/jaylann/gbar/pull/482",
        state: "open",
        createdAt: Date(timeIntervalSinceNow: -7200),
        updatedAt: Date(timeIntervalSinceNow: -3600),
        user: .previewOctocat,
        repositoryURL: "https://api.github.com/repos/jaylann/gbar",
        pullRequest: PullRequestRef(htmlURL: "https://github.com/jaylann/gbar/pull/482", mergedAt: nil),
        draft: false
    )

    static let previewDraftPR = SearchIssue(
        id: 2,
        number: 486,
        title: "WIP: segmented navigation for the popover",
        htmlURL: "https://github.com/jaylann/gbar/pull/486",
        state: "open",
        createdAt: Date(timeIntervalSinceNow: -1800),
        updatedAt: Date(timeIntervalSinceNow: -600),
        user: .previewMe,
        repositoryURL: "https://api.github.com/repos/jaylann/gbar",
        pullRequest: PullRequestRef(htmlURL: "https://github.com/jaylann/gbar/pull/486", mergedAt: nil),
        draft: true
    )

    static let previewMergedPR = SearchIssue(
        id: 3,
        number: 470,
        title: "Scaffold the design token layer",
        htmlURL: "https://github.com/jaylann/gbar/pull/470",
        state: "closed",
        createdAt: Date(timeIntervalSinceNow: -172_800),
        updatedAt: Date(timeIntervalSinceNow: -90000),
        user: .previewMe,
        repositoryURL: "https://api.github.com/repos/jaylann/gbar",
        pullRequest: PullRequestRef(
            htmlURL: "https://github.com/jaylann/gbar/pull/470",
            mergedAt: Date(timeIntervalSinceNow: -90000)
        ),
        draft: false
    )

    static let previewOpenIssue = SearchIssue(
        id: 4,
        number: 118,
        title: "Popover flickers on first open before cache renders",
        htmlURL: "https://github.com/jaylann/gbar/issues/118",
        state: "open",
        createdAt: Date(timeIntervalSinceNow: -21600),
        updatedAt: Date(timeIntervalSinceNow: -21600),
        user: .previewOctocat,
        repositoryURL: "https://api.github.com/repos/jaylann/gbar",
        pullRequest: nil,
        draft: nil
    )

    static let previewClosedIssue = SearchIssue(
        id: 5,
        number: 96,
        title: "Support GitHub Enterprise base URL",
        htmlURL: "https://github.com/jaylann/gbar/issues/96",
        state: "closed",
        createdAt: Date(timeIntervalSinceNow: -1_209_600),
        updatedAt: Date(timeIntervalSinceNow: -1_209_600),
        user: .previewMe,
        repositoryURL: "https://api.github.com/repos/jaylann/gbar",
        pullRequest: nil,
        draft: nil
    )
}
#endif
