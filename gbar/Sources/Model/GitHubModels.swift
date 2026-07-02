import Foundation

/// A GitHub account (or org identity) whose search results feed a set of menu sections.
struct GitHubUser: Decodable, Hashable {
    let login: String
    let avatarURL: String?

    enum CodingKeys: String, CodingKey {
        case login
        case avatarURL = "avatar_url"
    }
}

/// A GitHub search API response over issues/PRs (`GET /search/issues`).
struct SearchResponse: Decodable {
    let totalCount: Int
    let items: [SearchIssue]

    enum CodingKeys: String, CodingKey {
        case totalCount = "total_count"
        case items
    }
}

/// One item from `/search/issues` — a pull request or an issue (they share this shape).
struct SearchIssue: Decodable, Identifiable {
    struct PullRequestRef: Decodable {
        let htmlURL: String?
        let mergedAt: Date?

        enum CodingKeys: String, CodingKey {
            case htmlURL = "html_url"
            case mergedAt = "merged_at"
        }
    }

    let id: Int
    let number: Int
    let title: String
    let htmlURL: String
    let state: String
    let createdAt: Date
    /// Last-activity timestamp — the recency signal the notification path uses to avoid banners
    /// for stale items. Optional so a payload missing it degrades to `createdAt` rather than
    /// failing to decode.
    let updatedAt: Date?
    let user: GitHubUser?
    let repositoryURL: String
    let pullRequest: PullRequestRef?
    let draft: Bool?

    enum CodingKeys: String, CodingKey {
        case id
        case number
        case title
        case htmlURL = "html_url"
        case state
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case user
        case repositoryURL = "repository_url"
        case pullRequest = "pull_request"
        case draft
    }

    var isPullRequest: Bool {
        pullRequest != nil
    }

    /// `owner/name` derived from the repository API URL.
    var repositorySlug: String {
        let parts = repositoryURL.split(separator: "/")
        guard parts.count >= 2 else { return repositoryURL }
        return "\(parts[parts.count - 2])/\(parts[parts.count - 1])"
    }
}

/// The full detail for a single pull request (`GET /repos/{owner}/{repo}/pulls/{number}`) —
/// a superset of `SearchIssue` with merge state used by quick actions.
struct PullRequestDetail: Decodable {
    /// The PR's head commit — `sha` is the ref check-runs are queried against; `ref` is the
    /// branch name shown in the check rows.
    struct Head: Decodable {
        let sha: String
        let ref: String
    }

    let id: Int
    let number: Int
    let title: String
    let state: String
    let htmlURL: String
    let merged: Bool?
    let mergeable: Bool?
    /// GitHub's composite merge verdict (`clean`/`unstable`/`blocked`/`dirty`/`behind`/…) —
    /// richer than `mergeable`, and the signal that decides whether the Merge button shows.
    let mergeableState: String?
    let draft: Bool?
    let user: GitHubUser?
    let createdAt: Date
    let updatedAt: Date?
    let head: Head

    enum CodingKeys: String, CodingKey {
        case id
        case number
        case title
        case state
        case htmlURL = "html_url"
        case merged
        case mergeable
        case mergeableState = "mergeable_state"
        case draft
        case user
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case head
    }
}

/// One review on a pull request (`GET /repos/{owner}/{repo}/pulls/{number}/reviews`).
/// `state` is `APPROVED`/`CHANGES_REQUESTED`/`COMMENTED`/`DISMISSED`/`PENDING`; reviews
/// come back in chronological order, so the last definitive one by a user wins.
struct PullRequestReview: Decodable {
    let user: GitHubUser?
    let state: String
    let submittedAt: Date?

    enum CodingKeys: String, CodingKey {
        case user
        case state
        case submittedAt = "submitted_at"
    }
}

/// Repository detail (`GET /repos/{owner}/{repo}`) — we need the viewer's `permissions` to
/// decide whether merging is even possible, plus the repo's enabled merge strategies to build
/// the inline merge-method picker.
struct RepositoryInfo: Decodable {
    struct Permissions: Decodable {
        let push: Bool
        let maintain: Bool?
        let admin: Bool
    }

    let permissions: Permissions?
    let allowMergeCommit: Bool?
    let allowSquashMerge: Bool?
    let allowRebaseMerge: Bool?

    enum CodingKeys: String, CodingKey {
        case permissions
        case allowMergeCommit = "allow_merge_commit"
        case allowSquashMerge = "allow_squash_merge"
        case allowRebaseMerge = "allow_rebase_merge"
    }

    /// The merge strategies this repo permits, in GitHub's canonical order. A `nil` flag means
    /// GitHub omitted it (e.g. a token without repo-admin scope) — default it to available so a
    /// method is never wrongly hidden.
    var allowedMergeMethods: [MergeMethod] {
        var methods: [MergeMethod] = []
        if allowMergeCommit ?? true { methods.append(.merge) }
        if allowSquashMerge ?? true { methods.append(.squash) }
        if allowRebaseMerge ?? true { methods.append(.rebase) }
        return methods
    }
}

/// One check run for a commit (`GET /repos/{owner}/{repo}/commits/{ref}/check-runs`).
/// `status` is the lifecycle (`queued`/`in_progress`/`completed`); `conclusion` is the
/// outcome (`success`/`failure`/…), populated only once `status == completed`.
struct CheckRun: Decodable, Identifiable {
    let id: Int
    let name: String
    let status: String
    let conclusion: String?
    let startedAt: Date?
    let completedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case status
        case conclusion
        case startedAt = "started_at"
        case completedAt = "completed_at"
    }
}

/// The envelope `GET .../check-runs` returns: a total plus the runs themselves.
struct CheckRunsResponse: Decodable {
    let checkRuns: [CheckRun]

    enum CodingKeys: String, CodingKey {
        case checkRuns = "check_runs"
    }
}

/// One starred repository (`GET /user/starred`). We only need the `owner/name` slug — the
/// starred set is a cross-cutting signal (which of my rows sit on a repo I star) plus a
/// per-tab filter, not a browsable list.
struct StarredRepo: Decodable {
    let fullName: String

    enum CodingKeys: String, CodingKey {
        case fullName = "full_name"
    }
}

/// One GitHub Actions workflow run (`GET /repos/{owner}/{repo}/actions/runs`). Unlike the
/// PR-scoped check runs, this surfaces runs on branches with no PR, scheduled/cron workflows,
/// and manual dispatches. `status` is the lifecycle (`queued`/`in_progress`/`completed`);
/// `conclusion` is the outcome, populated only once `status == completed`.
struct WorkflowRun: Decodable, Identifiable {
    let id: Int
    /// The workflow's name (e.g. "CI"). Shown as the row's secondary identity.
    let name: String
    /// GitHub's human title for the run (commit message / PR title). Falls back to `name` in the
    /// UI when absent so the row always has a title.
    let displayTitle: String?
    let headBranch: String?
    /// What triggered the run: `push`, `schedule`, `workflow_dispatch`, `pull_request`, …
    let event: String
    let status: String
    let conclusion: String?
    let htmlURL: String
    let runNumber: Int
    let createdAt: Date
    let updatedAt: Date
    /// When the run actually began executing — preferred over `createdAt` for the duration.
    let runStartedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case displayTitle = "display_title"
        case headBranch = "head_branch"
        case event
        case status
        case conclusion
        case htmlURL = "html_url"
        case runNumber = "run_number"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case runStartedAt = "run_started_at"
    }
}

/// The envelope `GET .../actions/runs` returns: a total plus the runs themselves.
struct WorkflowRunsResponse: Decodable {
    let workflowRuns: [WorkflowRun]

    enum CodingKeys: String, CodingKey {
        case workflowRuns = "workflow_runs"
    }
}

/// One release (`GET /repos/{owner}/{repo}/releases`) — a "what shipped" entry for a watched
/// repo. `name` is the human title (often blank, in which case the UI shows the tag);
/// `publishedAt` is nil for drafts, so the digest sorts on `publishedAt ?? createdAt`.
struct Release: Decodable, Identifiable {
    let id: Int
    let tagName: String
    let name: String?
    let htmlURL: String
    let publishedAt: Date?
    let createdAt: Date
    let draft: Bool
    let prerelease: Bool
    let author: GitHubUser?

    enum CodingKeys: String, CodingKey {
        case id
        case tagName = "tag_name"
        case name
        case htmlURL = "html_url"
        case publishedAt = "published_at"
        case createdAt = "created_at"
        case draft
        case prerelease
        case author
    }
}

/// One item from `GET /notifications` — an unread/read thread pointing at a PR, issue, etc.
struct GitHubNotification: Decodable, Identifiable {
    struct Subject: Decodable {
        let title: String
        let type: String
        let url: String?

        enum CodingKeys: String, CodingKey {
            case title
            case type
            case url
        }
    }

    struct Repo: Decodable {
        let fullName: String

        enum CodingKeys: String, CodingKey {
            case fullName = "full_name"
        }
    }

    let id: String
    let unread: Bool
    let reason: String
    let updatedAt: Date
    let subject: Subject
    let repository: Repo

    enum CodingKeys: String, CodingKey {
        case id
        case unread
        case reason
        case updatedAt = "updated_at"
        case subject
        case repository
    }
}
