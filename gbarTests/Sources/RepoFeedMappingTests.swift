import XCTest
@testable import gbar

/// Covers the wire → row-model bridges for the per-repo feeds (`ActionRunRow.Model` /
/// `ReleaseRow.Model`), mirroring `NotificationMappingTests`.
final class RepoFeedMappingTests: XCTestCase {
    private func makeAccount(login: String = "octocat") throws -> Account {
        try Account(
            login: login,
            avatarURL: nil,
            kind: .oauth,
            apiBaseURL: XCTUnwrap(URL(string: "https://api.github.com"))
        )
    }

    // MARK: - ActionRunRow.Model

    func testActionRunModelUsesDisplayTitle() throws {
        let item = try AccountActionRun(
            account: makeAccount(),
            repo: "octo/repo",
            run: .stub(id: 9, name: "CI", displayTitle: "Fix the thing", event: "push")
        )

        let model = ActionRunRow.Model(item, isStarred: true)

        XCTAssertEqual(model.id, "octocat#octo/repo#9")
        XCTAssertEqual(model.repo, "octo/repo")
        XCTAssertEqual(model.title, "Fix the thing")
        XCTAssertEqual(model.workflow, "CI")
        XCTAssertEqual(model.event, "push")
        XCTAssertTrue(model.isStarred)
    }

    func testActionRunModelFallsBackToWorkflowNameWhenTitleMissingOrEmpty() throws {
        let missing = try AccountActionRun(
            account: makeAccount(), repo: "octo/repo", run: .stub(displayTitle: nil)
        )
        let empty = try AccountActionRun(
            account: makeAccount(), repo: "octo/repo", run: .stub(displayTitle: "")
        )

        XCTAssertEqual(ActionRunRow.Model(missing).title, "CI")
        XCTAssertEqual(ActionRunRow.Model(empty).title, "CI")
    }

    func testActionRunModelDropsEmptyBranch() throws {
        let item = try AccountActionRun(
            account: makeAccount(), repo: "octo/repo", run: .stub(headBranch: "")
        )

        XCTAssertNil(ActionRunRow.Model(item).branch)
    }

    func testHumanizedEventMapsKnownTriggersAndPassesUnknownThrough() {
        XCTAssertEqual(ActionRunRow.Model.humanizedEvent("workflow_dispatch"), "manual")
        XCTAssertEqual(ActionRunRow.Model.humanizedEvent("pull_request"), "pull request")
        XCTAssertEqual(ActionRunRow.Model.humanizedEvent("pull_request_target"), "pull request")
        XCTAssertEqual(ActionRunRow.Model.humanizedEvent("workflow_run"), "workflow")
        XCTAssertEqual(ActionRunRow.Model.humanizedEvent("push"), "push")
        XCTAssertEqual(ActionRunRow.Model.humanizedEvent("schedule"), "schedule")
    }

    // MARK: - ReleaseRow.Model

    func testReleaseModelUsesNameAndFlags() throws {
        let item = try AccountRelease(
            account: makeAccount(),
            repo: "octo/repo",
            release: .stub(id: 3, tagName: "v2.0.0", name: "Big Two", prerelease: true)
        )

        let model = ReleaseRow.Model(item)

        XCTAssertEqual(model.id, "octocat#octo/repo#3")
        XCTAssertEqual(model.title, "Big Two")
        XCTAssertEqual(model.tag, "v2.0.0")
        XCTAssertTrue(model.isPrerelease)
        XCTAssertFalse(model.isStarred)
    }

    func testReleaseModelFallsBackToTagWhenNameMissingOrEmpty() throws {
        let missing = try AccountRelease(
            account: makeAccount(), repo: "octo/repo", release: .stub(tagName: "v1.2.3", name: nil)
        )
        let empty = try AccountRelease(
            account: makeAccount(), repo: "octo/repo", release: .stub(tagName: "v1.2.3", name: "")
        )

        XCTAssertEqual(ReleaseRow.Model(missing).title, "v1.2.3")
        XCTAssertEqual(ReleaseRow.Model(empty).title, "v1.2.3")
    }

    func testReleaseModelDraftSortsOnCreatedAt() throws {
        // Drafts have no publishedAt; sortDate must fall back to createdAt (stub pins it).
        let draft = try AccountRelease(
            account: makeAccount(), repo: "octo/repo", release: .stub(publishedAt: nil, draft: true)
        )

        XCTAssertEqual(ReleaseRow.Model(draft).date, draft.release.createdAt)
    }
}
