import Foundation

/// Which GitHub merge strategy to use when merging a pull request. Raw values match the
/// `merge_method` strings the REST API expects.
enum MergeMethod: String, CaseIterable {
    case merge
    case squash
    case rebase

    /// Button text for the inline merge-method picker. Text (not an SF Symbol) reads clearer
    /// for three near-synonymous strategies, and the row is the only consumer.
    var label: String {
        switch self {
        case .merge: "Merge"
        case .squash: "Squash"
        case .rebase: "Rebase"
        }
    }
}

/// The GitHub data surface gbar needs. A protocol so the store can be tested against a
/// fake, and so a future hosted/webhook backend can drop in behind the same interface.
protocol GitHubAPI: Sendable {
    /// Fetch the authenticated user (`GET /user`) — resolves a token to its account, used to
    /// label and validate accounts on add.
    func currentUser() async throws -> GitHubUser
    /// Run a `/search/issues` query and return the matching PRs/issues.
    func searchIssues(_ query: String) async throws -> [SearchIssue]
    /// Fetch the full detail for a single pull request (`owner/name` slug + number).
    func pullRequest(repo: String, number: Int) async throws -> PullRequestDetail
    /// Fetch the reviews submitted on a pull request (`owner/name` slug + number).
    func reviews(repo: String, number: Int) async throws -> [PullRequestReview]
    /// Fetch a repository's detail (`owner/name` slug) — used for the viewer's permissions.
    func repository(repo: String) async throws -> RepositoryInfo
    /// Submit an approving review on a pull request, with an optional review body.
    func approvePullRequest(repo: String, number: Int, body: String?) async throws
    /// Merge a pull request using the given strategy.
    func mergePullRequest(repo: String, number: Int, method: MergeMethod) async throws
    /// Mark a notification thread as read.
    func markNotificationRead(threadID: String) async throws
    /// Mark every notification for the authenticated user as read (`PUT /notifications`).
    func markAllNotificationsRead() async throws
    /// Fetch the signed-in user's notifications.
    func notifications() async throws -> [GitHubNotification]
    /// Fetch the check runs for a commit (`owner/name` slug + git ref/SHA).
    func checkRuns(repo: String, ref: String) async throws -> [CheckRun]
    /// Fetch the `owner/name` slugs of every repository the viewer has starred. Paginated
    /// internally; the result is a cross-tab "starred" signal, not a browsable list.
    func starredRepos() async throws -> [String]
    /// Fetch the most recent GitHub Actions workflow runs for a repo (`owner/name` slug).
    func workflowRuns(repo: String) async throws -> [WorkflowRun]
    /// Fetch the most recent releases for a repo (`owner/name` slug).
    func releases(repo: String) async throws -> [Release]
}

/// Live GitHub REST client. v1 uses polling over `/search/issues`; richer surfaces
/// (checks, notifications, quick actions) are on the roadmap in docs/PRODUCT.md.
struct GitHubClient: GitHubAPI {
    enum ClientError: Error, Equatable {
        case http(Int)
        case badURL
    }

    let baseURL: URL
    let token: String
    private let session: URLSession

    init(baseURL: URL, token: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
    }

    func currentUser() async throws -> GitHubUser {
        let request = try makeRequest(path: "user")
        let data = try await execute(request)
        return try Self.decoder.decode(GitHubUser.self, from: data)
    }

    func searchIssues(_ query: String) async throws -> [SearchIssue] {
        let request = try makeRequest(
            path: "search/issues",
            queryItems: [
                URLQueryItem(name: "q", value: query),
                // Sort by recency (not GitHub's default unstable `best-match`) so the fetched
                // window is deterministic across polls: with more matches than `per_page`, an
                // unsorted query returns a shifting subset, making dormant items churn in/out
                // and re-fire "new item" notifications. Newest-updated first also reads best.
                URLQueryItem(name: "sort", value: "updated"),
                URLQueryItem(name: "order", value: "desc"),
                URLQueryItem(name: "per_page", value: "50"),
            ]
        )
        let data = try await execute(request)
        return try Self.decoder.decode(SearchResponse.self, from: data).items
    }

    func pullRequest(repo: String, number: Int) async throws -> PullRequestDetail {
        let request = try makeRequest(path: "repos/\(repo)/pulls/\(number)")
        let data = try await execute(request)
        return try Self.decoder.decode(PullRequestDetail.self, from: data)
    }

    func reviews(repo: String, number: Int) async throws -> [PullRequestReview] {
        let request = try makeRequest(
            path: "repos/\(repo)/pulls/\(number)/reviews",
            queryItems: [URLQueryItem(name: "per_page", value: "100")]
        )
        let data = try await execute(request)
        return try Self.decoder.decode([PullRequestReview].self, from: data)
    }

    func repository(repo: String) async throws -> RepositoryInfo {
        let request = try makeRequest(path: "repos/\(repo)")
        let data = try await execute(request)
        return try Self.decoder.decode(RepositoryInfo.self, from: data)
    }

    func approvePullRequest(repo: String, number: Int, body: String?) async throws {
        var payload = ["event": "APPROVE"]
        if let body, !body.isEmpty { payload["body"] = body }
        let request = try makeRequest(
            path: "repos/\(repo)/pulls/\(number)/reviews",
            method: "POST",
            body: payload
        )
        _ = try await execute(request)
    }

    func mergePullRequest(repo: String, number: Int, method: MergeMethod) async throws {
        let request = try makeRequest(
            path: "repos/\(repo)/pulls/\(number)/merge",
            method: "PUT",
            body: ["merge_method": method.rawValue]
        )
        _ = try await execute(request)
    }

    func markNotificationRead(threadID: String) async throws {
        let request = try makeRequest(path: "notifications/threads/\(threadID)", method: "PATCH")
        _ = try await execute(request)
    }

    func markAllNotificationsRead() async throws {
        let request = try makeRequest(path: "notifications", method: "PUT")
        _ = try await execute(request)
    }

    func notifications() async throws -> [GitHubNotification] {
        let request = try makeRequest(path: "notifications")
        let data = try await execute(request)
        return try Self.decoder.decode([GitHubNotification].self, from: data)
    }

    func checkRuns(repo: String, ref: String) async throws -> [CheckRun] {
        let request = try makeRequest(path: "repos/\(repo)/commits/\(ref)/check-runs")
        let data = try await execute(request)
        return try Self.decoder.decode(CheckRunsResponse.self, from: data).checkRuns
    }

    /// Max pages of starred repos to walk. `starredPerPage` (100) × this cap bounds how many
    /// slugs the signal covers — plenty for a membership check, and a hard stop so an account
    /// that stars thousands of repos can't stall a refresh.
    static let starredPageCap = 5
    static let starredPerPage = 100

    func starredRepos() async throws -> [String] {
        var slugs: [String] = []
        var page = 1
        while page <= Self.starredPageCap {
            let request = try makeRequest(
                path: "user/starred",
                queryItems: [
                    URLQueryItem(name: "per_page", value: String(Self.starredPerPage)),
                    URLQueryItem(name: "page", value: String(page)),
                ]
            )
            let (data, response) = try await executeWithResponse(request)
            try slugs.append(contentsOf: Self.decoder.decode([StarredRepo].self, from: data).map(\.fullName))
            // Stop as soon as GitHub reports no `rel="next"` — the last page is usually short of
            // `per_page`, so this avoids a wasted trailing request.
            guard Self.hasNextPage(response) else { return slugs }
            page += 1
        }
        Log.network
            .info("starred list truncated at \(Self.starredPageCap * Self.starredPerPage, privacy: .public) repos")
        return slugs
    }

    func workflowRuns(repo: String) async throws -> [WorkflowRun] {
        let request = try makeRequest(
            path: "repos/\(repo)/actions/runs",
            queryItems: [URLQueryItem(name: "per_page", value: "10")]
        )
        let data = try await execute(request)
        return try Self.decoder.decode(WorkflowRunsResponse.self, from: data).workflowRuns
    }

    func releases(repo: String) async throws -> [Release] {
        let request = try makeRequest(
            path: "repos/\(repo)/releases",
            queryItems: [URLQueryItem(name: "per_page", value: "5")]
        )
        let data = try await execute(request)
        return try Self.decoder.decode([Release].self, from: data)
    }

    /// Whether the response's `Link` header advertises a `rel="next"` page.
    private static func hasNextPage(_ response: HTTPURLResponse) -> Bool {
        guard let link = response.value(forHTTPHeaderField: "Link") else { return false }
        return link.contains("rel=\"next\"")
    }

    // MARK: - Request plumbing

    /// A JSON decoder configured the way every GitHub response expects.
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// A shared JSON encoder for request bodies — cheaper than allocating one per request.
    private static let encoder = JSONEncoder()

    /// Build a request against `baseURL` with gbar's standard headers, optional query items,
    /// and an optional JSON body (which also sets `Content-Type`).
    private func makeRequest(
        path: String,
        method: String = "GET",
        queryItems: [URLQueryItem]? = nil,
        body: [String: String]? = nil
    ) throws
    -> URLRequest {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        ) else {
            throw ClientError.badURL
        }
        components.queryItems = queryItems
        guard let url = components.url else { throw ClientError.badURL }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("gbar", forHTTPHeaderField: "User-Agent")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try Self.encoder.encode(body)
        }
        return request
    }

    /// Run a request and return its body, throwing `ClientError.http` on any non-2xx status.
    private func execute(_ request: URLRequest) async throws -> Data {
        try await executeWithResponse(request).0
    }

    /// Run a request and return its body **and** response, throwing `ClientError.http` on any
    /// non-2xx status. Used where a response header matters (e.g. the `Link` pagination cursor).
    private func executeWithResponse(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ClientError.http((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return (data, http)
    }
}
