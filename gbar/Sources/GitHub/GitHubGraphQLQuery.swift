import Foundation

/// Builds the batched GraphQL query that collapses the per-PR REST hydration N+1 into one
/// round-trip, and decodes the response back into the REST-shaped value types the store already
/// consumes (see `GraphQLPRMapping.swift`). Pure/stateless so both halves are unit-testable
/// without a network.
enum GitHubGraphQL {
    /// The `{ "query": …, "variables": … }` POST body GitHub's GraphQL endpoint expects.
    struct RequestBody: Encodable {
        let query: String
        let variables: [String: Value]

        /// A GraphQL variable value — only the two scalar shapes this query needs (repo
        /// owner/name strings and the PR number int), encoded as a bare JSON scalar.
        enum Value: Encodable {
            case string(String)
            case int(Int)

            func encode(to encoder: Encoder) throws {
                var container = encoder.singleValueContainer()
                switch self {
                case let .string(value): try container.encode(value)
                case let .int(value): try container.encode(value)
                }
            }
        }
    }

    /// The PR fields fetched per node — mirrors exactly what the REST detail + reviews + check-runs
    /// triple returns, so the mapping can reconstruct `PullRequestDetail`/`PullRequestReview`/
    /// `CheckRun`. `mergeStateStatus` is GraphQL's analogue of REST `mergeable_state`; an older GHE
    /// server that doesn't expose it fails the whole query → the caller falls back to REST.
    private static let prFragment = """
    fragment PRF on PullRequest {
      number state isDraft mergeable mergeStateStatus headRefOid headRefName
      title url databaseId createdAt updatedAt
      author { login }
      reviews(last: 100) { nodes { author { login } state submittedAt } }
      commits(last: 1) { nodes { commit { statusCheckRollup {
        state
        contexts(first: 100) { nodes {
          __typename
          ... on CheckRun { databaseId name status conclusion startedAt completedAt }
          ... on StatusContext { context state createdAt }
        } }
      } } } }
    }
    """

    /// The viewer's merge signals, read off the same `repository` node the PR is fetched under —
    /// so folding repo permissions into the batch costs no extra round-trip.
    private static let repoFields = "viewerPermission mergeCommitAllowed squashMergeAllowed rebaseMergeAllowed"

    /// Build the aliased batch query + variables for a chunk of PR refs. Each ref becomes an
    /// `r{i}: repository(owner:$o{i}, name:$n{i}) { … pullRequest(number:$p{i}) { …PRF } }`
    /// selection so a single query resolves them all; the response aliases map back by index.
    static func batchQuery(for refs: [PRRef]) -> RequestBody {
        var params: [String] = []
        var selections: [String] = []
        var variables: [String: RequestBody.Value] = [:]
        for (index, ref) in refs.enumerated() {
            let (owner, name) = splitSlug(ref.repo)
            params.append("$o\(index): String!, $n\(index): String!, $p\(index): Int!")
            selections.append(
                "r\(index): repository(owner: $o\(index), name: $n\(index)) "
                    + "{ \(repoFields) pullRequest(number: $p\(index)) { ...PRF } }"
            )
            variables["o\(index)"] = .string(owner)
            variables["n\(index)"] = .string(name)
            variables["p\(index)"] = .int(ref.number)
        }
        let query = """
        query BatchPRs(\(params.joined(separator: ", "))) {
        \(selections.joined(separator: "\n"))
        }
        \(prFragment)
        """
        return RequestBody(query: query, variables: variables)
    }

    /// Split an `owner/name` slug. A malformed slug (no `/`) keeps the whole string as the owner
    /// and an empty name, which GitHub resolves to a null node the mapping skips.
    static func splitSlug(_ slug: String) -> (owner: String, name: String) {
        let parts = slug.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return (slug, "") }
        return (String(parts[0]), String(parts[1]))
    }
}

extension Array {
    /// Split into contiguous sub-arrays of at most `size` elements (the last may be shorter).
    /// `size <= 0` yields a single chunk with everything, so a misconfigured batch size can't loop.
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return isEmpty ? [] : [self] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
