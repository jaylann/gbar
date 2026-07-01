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
