import XCTest
@testable import gbar

final class SearchQueryTests: XCTestCase {
    private func section(query: String, kind: SearchQuery.Section.Kind? = nil) -> SearchQuery.Section {
        SearchQuery.Section(id: "x", title: "X", query: query, kind: kind)
    }

    func testInferredKindReadsIsIssueAsIssues() {
        XCTAssertEqual(section(query: "is:open is:issue assignee:@me").inferredKind, .issues)
    }

    func testInferredKindDefaultsToPRs() {
        XCTAssertEqual(section(query: "is:open is:pr review-requested:@me").inferredKind, .prs)
        // Bare / unrecognized queries fall back to PRs rather than guessing issues.
        XCTAssertEqual(section(query: "assignee:@me").inferredKind, .prs)
    }

    func testInferredKindIsCaseInsensitive() {
        XCTAssertEqual(section(query: "IS:ISSUE label:bug").inferredKind, .issues)
    }

    func testResolvedKindPrefersExplicitChoiceOverInference() {
        // Query looks like issues, but the user pinned it to PRs — the explicit choice wins.
        XCTAssertEqual(section(query: "is:issue", kind: .prs).resolvedKind, .prs)
        // No explicit choice → fall back to inference.
        XCTAssertEqual(section(query: "is:issue").resolvedKind, .issues)
    }

    func testDefaultsRouteToExpectedTabs() {
        let byID = Dictionary(uniqueKeysWithValues: SearchQuery.defaults.map { ($0.id, $0.resolvedKind) })
        XCTAssertEqual(byID["review-requested"], .prs)
        XCTAssertEqual(byID["assigned-prs"], .prs)
        XCTAssertEqual(byID["created-prs"], .prs)
        XCTAssertEqual(byID["assigned-issues"], .issues)
    }

    func testKindRoundTripsThroughCodable() throws {
        let original = section(query: "is:pr", kind: .issues)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SearchQuery.Section.self, from: data)
        XCTAssertEqual(decoded.kind, .issues)
    }

    func testDecodingLegacyBlobWithoutKindLeavesItNil() throws {
        // A section persisted before `kind` existed decodes with `kind == nil` (auto).
        let legacy = #"{"id":"x","title":"X","query":"is:pr"}"#
        let decoded = try JSONDecoder().decode(SearchQuery.Section.self, from: Data(legacy.utf8))
        XCTAssertNil(decoded.kind)
        XCTAssertEqual(decoded.resolvedKind, .prs)
    }
}
