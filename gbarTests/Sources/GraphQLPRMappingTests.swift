import XCTest
@testable import gbar

/// Covers the GraphQL batch query builder + the decode/map back onto the REST-shaped value types.
/// The mapping is the load-bearing part of issue #83: a GraphQL-hydrated PR must be
/// indistinguishable from a REST one downstream (`deriveGate`/`ciRollup`).
final class GraphQLPRMappingTests: XCTestCase {
    private let refs = [PRRef(repo: "octo/repo", number: 7), PRRef(repo: "octo/other", number: 9)]

    /// A response with one full node (`r0`) and one null node (`r1`, e.g. no access).
    private func fixture(mergeStateStatus: String = "BLOCKED") -> Data {
        let json = """
        {
          "data": {
            "r0": {
              "viewerPermission": "WRITE",
              "mergeCommitAllowed": true, "squashMergeAllowed": false, "rebaseMergeAllowed": true,
              "pullRequest": {
                "number": 7, "state": "OPEN", "isDraft": false,
                "mergeable": "MERGEABLE", "mergeStateStatus": "\(mergeStateStatus)",
                "headRefOid": "abc123", "headRefName": "feature/x",
                "title": "A PR", "url": "https://github.com/octo/repo/pull/7", "databaseId": 700,
                "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-01-02T00:00:00Z",
                "author": { "login": "contributor" },
                "reviews": { "nodes": [
                  { "author": { "login": "octocat" }, "state": "APPROVED", "submittedAt": "2026-01-01T00:00:00Z" }
                ] },
                "commits": { "nodes": [ { "commit": { "statusCheckRollup": {
                  "state": "FAILURE",
                  "contexts": { "nodes": [
                    { "__typename": "CheckRun", "databaseId": 11, "name": "CI / build",
                      "status": "COMPLETED", "conclusion": "FAILURE",
                      "startedAt": "2026-01-01T00:00:00Z", "completedAt": "2026-01-01T00:01:00Z" },
                    { "__typename": "StatusContext", "context": "ci/legacy", "state": "SUCCESS",
                      "createdAt": "2026-01-01T00:00:00Z" }
                  ] }
                } } } ] }
              }
            },
            "r1": null
          }
        }
        """
        return Data(json.utf8)
    }

    func testMapsNodeIntoRESTShapes() throws {
        let result = try GitHubGraphQL.decodeBatch(fixture(), for: refs)
        // r1 was null → tolerated (absent), only r0 comes back.
        XCTAssertEqual(result.count, 1)
        XCTAssertNil(result[refs[1]])
        let bundle = try XCTUnwrap(result[refs[0]])

        XCTAssertEqual(bundle.detail.number, 7)
        XCTAssertEqual(bundle.detail.state, "open")
        XCTAssertEqual(bundle.detail.mergeableState, "blocked")
        XCTAssertEqual(bundle.detail.draft, false)
        XCTAssertEqual(bundle.detail.head.sha, "abc123")
        XCTAssertEqual(bundle.detail.head.ref, "feature/x")
        XCTAssertEqual(bundle.detail.user?.login, "contributor")

        XCTAssertEqual(bundle.reviews.count, 1)
        XCTAssertEqual(bundle.reviews.first?.user?.login, "octocat")
        XCTAssertEqual(bundle.reviews.first?.state, "APPROVED")

        // Only the CheckRun is consumed (the StatusContext is filtered to match REST) → failure.
        XCTAssertEqual(bundle.checkRuns.count, 1)
        XCTAssertEqual(bundle.checkRuns.ciRollup, .failure)

        // WRITE permission → mergeable; squash disabled → only merge + rebase offered.
        XCTAssertEqual(bundle.mergeInfo?.canMerge, true)
        XCTAssertEqual(bundle.mergeInfo?.allowedMethods, [.merge, .rebase])
    }

    /// The mapped `PullRequestBundle` must drive `deriveGate` to the same verdict a REST hydration
    /// would — this is the whole point of the transport swap.
    func testMappedBundleDrivesGate() throws {
        let bundle = try XCTUnwrap(GitHubGraphQL.decodeBatch(fixture(mergeStateStatus: "CLEAN"), for: refs)[refs[0]])
        let gate = AppStore.deriveGate(
            detail: bundle.detail, reviews: bundle.reviews, login: "octocat", mergeInfo: bundle.mergeInfo
        )
        XCTAssertTrue(gate.alreadyApproved, "octocat's APPROVED review should mark the gate approved")
        XCTAssertTrue(gate.mergeable, "clean + WRITE access → mergeable")
    }

    func testMergeStateStatusMapping() throws {
        let cases: [(String, String?)] = [
            ("CLEAN", "clean"), ("UNSTABLE", "unstable"), ("HAS_HOOKS", "has_hooks"),
            ("BLOCKED", "blocked"), ("DIRTY", "dirty"), ("BEHIND", "behind"),
            ("UNKNOWN", nil), ("DRAFT", nil),
        ]
        for (graphQL, expected) in cases {
            let bundle = try XCTUnwrap(GitHubGraphQL.decodeBatch(fixture(mergeStateStatus: graphQL), for: refs)[refs[0]])
            XCTAssertEqual(bundle.detail.mergeableState, expected, "\(graphQL) should map to \(expected ?? "nil")")
        }
    }

    /// Legacy StatusContext nodes are filtered out so the CI rollup matches the REST check-runs
    /// endpoint exactly (which never returns commit statuses) — no divergence between the batch
    /// path and its REST fallback.
    func testStatusContextFilteredToMatchREST() throws {
        let bundle = try XCTUnwrap(GitHubGraphQL.decodeBatch(fixture(), for: refs)[refs[0]])
        XCTAssertFalse(bundle.checkRuns.contains { $0.name == "ci/legacy" }, "legacy status must be dropped")
        XCTAssertTrue(bundle.checkRuns.allSatisfy { $0.name == "CI / build" })
    }

    func testTopLevelErrorsWithoutDataThrows() {
        let json = Data(#"{"data":null,"errors":[{"message":"Field 'mergeStateStatus' doesn't exist"}]}"#.utf8)
        XCTAssertThrowsError(try GitHubGraphQL.decodeBatch(json, for: refs)) { error in
            guard case let GitHubClient.ClientError.graphQL(message) = error else {
                return XCTFail("expected .graphQL, got \(error)")
            }
            XCTAssertTrue(message.contains("mergeStateStatus"))
        }
    }

    // MARK: - Query builder

    func testBatchQueryBuildsAliasesAndVariables() {
        let body = GitHubGraphQL.batchQuery(for: refs)
        XCTAssertTrue(body.query.contains("r0: repository(owner: $o0, name: $n0)"))
        XCTAssertTrue(body.query.contains("r1: repository(owner: $o1, name: $n1)"))
        XCTAssertTrue(body.query.contains("pullRequest(number: $p1)"))
        // Variables carry the split slug + number for each ref.
        if case let .string(owner) = body.variables["o0"] { XCTAssertEqual(owner, "octo") } else { XCTFail("o0") }
        if case let .string(name) = body.variables["n1"] { XCTAssertEqual(name, "other") } else { XCTFail("n1") }
        if case let .int(number) = body.variables["p0"] { XCTAssertEqual(number, 7) } else { XCTFail("p0") }
    }

    func testSplitSlug() {
        XCTAssertTrue(GitHubGraphQL.splitSlug("octo/repo") == ("octo", "repo"))
        // A malformed slug keeps the whole string as owner (GitHub nulls the node, mapping skips it).
        XCTAssertTrue(GitHubGraphQL.splitSlug("noslash") == ("noslash", ""))
    }

    func testChunked() {
        XCTAssertEqual([1, 2, 3, 4, 5].chunked(into: 2), [[1, 2], [3, 4], [5]])
        XCTAssertEqual([Int]().chunked(into: 2), [])
        XCTAssertEqual([1, 2].chunked(into: 0), [[1, 2]]) // guard against a misconfigured size
    }
}
