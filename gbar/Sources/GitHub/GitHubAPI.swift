import Foundation

/// Which GitHub merge strategy to use when merging a pull request. Raw values match the
/// `merge_method` strings the REST API expects.
enum MergeMethod: String {
    case merge
    case squash
    case rebase
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
    /// Submit an approving review on a pull request.
    func approvePullRequest(repo: String, number: Int) async throws
    /// Merge a pull request using the given strategy.
    func mergePullRequest(repo: String, number: Int, method: MergeMethod) async throws
    /// Mark a notification thread as read.
    func markNotificationRead(threadID: String) async throws
    /// Fetch the signed-in user's notifications.
    func notifications() async throws -> [GitHubNotification]
    /// Fetch the check runs for a commit (`owner/name` slug + git ref/SHA).
    func checkRuns(repo: String, ref: String) async throws -> [CheckRun]
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

    func approvePullRequest(repo: String, number: Int) async throws {
        let request = try makeRequest(
            path: "repos/\(repo)/pulls/\(number)/reviews",
            method: "POST",
            body: ["event": "APPROVE"]
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
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ClientError.http((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return data
    }
}
