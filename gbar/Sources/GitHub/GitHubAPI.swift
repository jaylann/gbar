import Foundation

/// The GitHub data surface gbar needs. A protocol so the store can be tested against a
/// fake, and so a future hosted/webhook backend can drop in behind the same interface.
protocol GitHubAPI: Sendable {
    /// Run a `/search/issues` query and return the matching PRs/issues.
    func searchIssues(_ query: String) async throws -> [SearchIssue]
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

    func searchIssues(_ query: String) async throws -> [SearchIssue] {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent("search/issues"),
            resolvingAgainstBaseURL: false
        ) else {
            throw ClientError.badURL
        }
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "per_page", value: "50"),
        ]
        guard let url = components.url else { throw ClientError.badURL }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("gbar", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ClientError.http((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SearchResponse.self, from: data).items
    }
}
