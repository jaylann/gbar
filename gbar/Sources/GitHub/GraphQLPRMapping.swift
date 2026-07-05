import Foundation

/// Decodes a batched GraphQL response and maps each PR node back onto the REST-shaped value types
/// (`PullRequestDetail` / `PullRequestReview` / `CheckRun` / `RepoMergeInfo`) so the store's
/// existing `deriveGate` / `ciRollup` / `checkRowModel` derivation consumes a batched result with
/// no change. GraphQL is a transport swap, not a logic rewrite.
extension GitHubGraphQL {
    /// Decode a chunk's response and return one `PullRequestBundle` per resolvable ref, keyed by
    /// the ref. Per-node nulls (a repo/PR the viewer can't see, or a repo you lost access to) are
    /// tolerated — that ref is simply absent, exactly like a failed REST fetch. Throws
    /// `GitHubClient.ClientError.graphQL` only when the whole response is unusable (top-level
    /// `errors` with no `data`), so the caller can fall back to REST.
    static func decodeBatch(_ data: Data, for refs: [PRRef]) throws -> [PRRef: PullRequestBundle] {
        let response = try decoder.decode(Response.self, from: data)
        guard let repos = response.data?.repos else {
            let message = response.errors?.first?.message ?? "GraphQL response carried no data"
            throw GitHubClient.ClientError.graphQL(message)
        }
        var result: [PRRef: PullRequestBundle] = [:]
        for (index, ref) in refs.enumerated() {
            guard let repo = repos["r\(index)"], let pr = repo.pullRequest else { continue }
            result[ref] = pr.bundle(repo: repo)
        }
        return result
    }

    /// A GraphQL DateTime decoder mirroring `GitHubClient`'s tolerant ISO8601 handling (accepts
    /// both plain and fractional-second `Z` timestamps) so one odd field can't fail the batch.
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        let plain = Date.ISO8601FormatStyle()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            guard let date = (try? fractional.parse(string)) ?? (try? plain.parse(string)) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Invalid ISO8601 date: \(string)"
                )
            }
            return date
        }
        return decoder
    }()

    // MARK: - Response shape

    /// The GraphQL envelope: `data` (nil on a hard failure) plus any `errors`.
    struct Response: Decodable {
        let data: Payload?
        let errors: [GraphQLError]?
    }

    struct GraphQLError: Decodable {
        let message: String
    }

    /// The `data` object — its keys are the per-PR `r{i}` aliases. Decoded through a dynamic
    /// container so null nodes are skipped rather than failing the decode.
    struct Payload: Decodable {
        let repos: [String: RepositoryNode]

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: GraphQLDynamicKey.self)
            var repos: [String: RepositoryNode] = [:]
            for key in container.allKeys {
                if let node = try container.decodeIfPresent(RepositoryNode.self, forKey: key) {
                    repos[key.stringValue] = node
                }
            }
            self.repos = repos
        }
    }

    struct RepositoryNode: Decodable {
        let viewerPermission: String?
        let mergeCommitAllowed: Bool?
        let squashMergeAllowed: Bool?
        let rebaseMergeAllowed: Bool?
        let pullRequest: PRNode?
    }

    // The connection nodes are kept flat (siblings under `GitHubGraphQL`, not nested inside
    // `PRNode`) to stay within the nesting limit while mirroring GitHub's `edges`/`nodes` shape.

    struct PRNode: Decodable {
        let number: Int
        let state: String
        let isDraft: Bool
        let mergeable: String?
        let mergeStateStatus: String?
        let headRefOid: String
        let headRefName: String
        let title: String?
        let url: String?
        let databaseId: Int?
        let createdAt: Date?
        let updatedAt: Date?
        let author: Author?
        let reviews: ReviewConnection?
        let commits: CommitConnection?
    }

    struct Author: Decodable { let login: String }
    struct ReviewConnection: Decodable { let nodes: [ReviewNode]? }
    struct ReviewNode: Decodable {
        let author: Author?
        let state: String
        let submittedAt: Date?
    }

    struct CommitConnection: Decodable { let nodes: [CommitNode]? }
    struct CommitNode: Decodable { let commit: Commit }
    struct Commit: Decodable { let statusCheckRollup: Rollup? }
    struct Rollup: Decodable { let contexts: ContextConnection? }
    struct ContextConnection: Decodable { let nodes: [ContextNode]? }

    /// A `statusCheckRollup` context — either a `CheckRun` (Actions/apps) or a legacy
    /// `StatusContext` (commit status API). The two shapes are merged into one optional-heavy
    /// struct discriminated by `__typename`.
    struct ContextNode: Decodable {
        let typename: String
        // CheckRun
        let databaseId: Int?
        let name: String?
        let status: String?
        let conclusion: String?
        let startedAt: Date?
        let completedAt: Date?
        // StatusContext
        let context: String?
        let state: String?

        enum CodingKeys: String, CodingKey {
            case typename = "__typename"
            case databaseId, name, status, conclusion, startedAt, completedAt, context, state
        }
    }
}

/// A `CodingKey` that accepts any string key — used to decode the GraphQL `data` object whose keys
/// are the dynamic `r{i}` PR aliases.
private struct GraphQLDynamicKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }

    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue _: Int) { nil }
}

// MARK: - Mapping to REST value types

extension GitHubGraphQL.PRNode {
    /// Reconstruct the REST-shaped `PullRequestBundle` for this PR node + its repository node.
    func bundle(repo: GitHubGraphQL.RepositoryNode) -> PullRequestBundle {
        let detail = PullRequestDetail(
            id: databaseId ?? number,
            number: number,
            title: title ?? "",
            state: state.lowercased(),
            htmlURL: url ?? "",
            merged: state == "MERGED",
            mergeable: Self.mergeableBool(mergeable),
            mergeableState: Self.mergeableState(mergeStateStatus),
            draft: isDraft,
            user: author.map { GitHubUser(login: $0.login, avatarURL: nil) },
            createdAt: createdAt ?? updatedAt ?? .distantPast,
            updatedAt: updatedAt,
            head: PullRequestDetail.Head(sha: headRefOid, ref: headRefName)
        )
        let reviewModels: [PullRequestReview] = (reviews?.nodes ?? []).map { node in
            PullRequestReview(
                user: node.author.map { GitHubUser(login: $0.login, avatarURL: nil) },
                state: node.state,
                submittedAt: node.submittedAt
            )
        }
        let contexts = commits?.nodes?.first?.commit.statusCheckRollup?.contexts?.nodes ?? []
        let checkRuns = contexts.enumerated().map { index, node in node.checkRun(index: index) }
        return PullRequestBundle(
            detail: detail,
            reviews: reviewModels,
            checkRuns: checkRuns,
            mergeInfo: repo.mergeInfo
        )
    }

    /// GraphQL's tri-state `mergeable` → REST's `Bool?`. `UNKNOWN` (GitHub still computing) stays
    /// nil so `deriveGate` treats it optimistically.
    private static func mergeableBool(_ value: String?) -> Bool? {
        switch value {
        case "MERGEABLE": true
        case "CONFLICTING": false
        default: nil
        }
    }

    /// GraphQL `mergeStateStatus` → REST `mergeable_state` string, so `deriveGate` reads it
    /// unchanged. `UNKNOWN`/nil map to nil (optimistic); `DRAFT` is left to the `draft` flag, which
    /// already gates the row. Only the definitively-bad states hide the Merge button.
    private static func mergeableState(_ value: String?) -> String? {
        switch value {
        case "CLEAN": "clean"
        case "UNSTABLE": "unstable"
        case "HAS_HOOKS": "has_hooks"
        case "BLOCKED": "blocked"
        case "DIRTY": "dirty"
        case "BEHIND": "behind"
        default: nil
        }
    }
}

extension GitHubGraphQL.ContextNode {
    /// Map one rollup context onto a `CheckRun` so the existing `ciRollup`/`checkRowModel` logic
    /// consumes it. GraphQL enum values are upper-cased; a `CheckRun` node lower-cases its
    /// status/conclusion to match REST, while a legacy `StatusContext` is synthesised into an
    /// equivalent completed/pending run. `index` guarantees a unique id when `databaseId` is absent.
    func checkRun(index: Int) -> CheckRun {
        if typename == "StatusContext" {
            let (mappedStatus, mappedConclusion) = Self.statusContextOutcome(state)
            return CheckRun(
                id: databaseId ?? index,
                name: context ?? "status",
                status: mappedStatus,
                conclusion: mappedConclusion,
                startedAt: nil,
                completedAt: nil
            )
        }
        return CheckRun(
            id: databaseId ?? index,
            name: name ?? "check",
            status: status?.lowercased() ?? "",
            conclusion: conclusion?.lowercased(),
            startedAt: startedAt,
            completedAt: completedAt
        )
    }

    /// Legacy commit-status `state` → a `(status, conclusion)` pair matching what `CheckRun.ciStatus`
    /// expects: success/failure resolve to `completed`; pending/expected read as in-progress.
    private static func statusContextOutcome(_ state: String?) -> (status: String, conclusion: String?) {
        switch state {
        case "SUCCESS": ("completed", "success")
        case "FAILURE",
             "ERROR": ("completed", "failure")
        default: ("in_progress", nil) // PENDING / EXPECTED / unknown → not yet settled
        }
    }
}

extension GitHubGraphQL.RepositoryNode {
    /// The viewer's merge signals from the repo node, or nil when `viewerPermission` is absent
    /// (unknown → `deriveGate` stays optimistic, matching a missing `repoMergeInfo` cache entry).
    var mergeInfo: RepoMergeInfo? {
        guard let permission = viewerPermission else { return nil }
        let canMerge = ["ADMIN", "MAINTAIN", "WRITE"].contains(permission)
        var methods: [MergeMethod] = []
        if mergeCommitAllowed ?? true { methods.append(.merge) }
        if squashMergeAllowed ?? true { methods.append(.squash) }
        if rebaseMergeAllowed ?? true { methods.append(.rebase) }
        return RepoMergeInfo(canMerge: canMerge, allowedMethods: methods)
    }
}
