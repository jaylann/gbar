import XCTest
@testable import gbar

final class WorkflowRunMappingTests: XCTestCase {
    // MARK: - WorkflowRun -> CIStatus

    func testStatusPendingWhenNotCompleted() {
        XCTAssertEqual(WorkflowRun.stub(status: "queued", conclusion: nil).ciStatus, .pending)
        XCTAssertEqual(WorkflowRun.stub(status: "in_progress", conclusion: nil).ciStatus, .pending)
        // A conclusion doesn't count until the run has completed.
        XCTAssertEqual(WorkflowRun.stub(status: "in_progress", conclusion: "success").ciStatus, .pending)
    }

    func testStatusSuccess() {
        XCTAssertEqual(WorkflowRun.stub(status: "completed", conclusion: "success").ciStatus, .success)
    }

    func testStatusFailureConclusions() {
        for conclusion in ["failure", "timed_out", "action_required", "startup_failure"] {
            XCTAssertEqual(
                WorkflowRun.stub(status: "completed", conclusion: conclusion).ciStatus,
                .failure,
                "expected \(conclusion) to map to .failure"
            )
        }
    }

    func testStatusNeutralConclusions() {
        for conclusion in ["neutral", "skipped", "cancelled", "stale"] {
            XCTAssertEqual(
                WorkflowRun.stub(status: "completed", conclusion: conclusion).ciStatus,
                .neutral,
                "expected \(conclusion) to map to .neutral"
            )
        }
    }

    func testStatusUnknownConclusionMapsToNeutral() {
        XCTAssertEqual(WorkflowRun.stub(status: "completed", conclusion: "brand_new").ciStatus, .neutral)
        XCTAssertEqual(WorkflowRun.stub(status: "completed", conclusion: nil).ciStatus, .neutral)
    }

    // MARK: - Duration

    func testDurationFromRunStartToUpdated() {
        // run_started_at 00:00:00 -> updated_at 00:01:42 == 1m 42s
        XCTAssertEqual(WorkflowRun.stub(updatedAt: "2026-01-01T00:01:42Z").durationText, "1m 42s")
    }

    func testDurationNilWhileRunning() {
        XCTAssertNil(WorkflowRun.stub(status: "in_progress", conclusion: nil).durationText)
    }

    func testDurationSecondsOnly() {
        XCTAssertEqual(WorkflowRun.stub(updatedAt: "2026-01-01T00:00:12Z").durationText, "12s")
    }

    // MARK: - ActionRunRow.Model mapping

    func testRowModelPrefersDisplayTitleThenFallsBackToWorkflowName() throws {
        let account = try Account(
            login: "octocat",
            avatarURL: nil,
            kind: .oauth,
            apiBaseURL: XCTUnwrap(URL(string: "https://api.github.com"))
        )
        let withTitle = AccountActionRun(account: account, repo: "octo/repo", run: .stub(displayTitle: "Ship it"))
        XCTAssertEqual(ActionRunRow.Model(withTitle).title, "Ship it")

        let noTitle = AccountActionRun(account: account, repo: "octo/repo", run: .stub(name: "CI", displayTitle: nil))
        XCTAssertEqual(ActionRunRow.Model(noTitle).title, "CI")
    }

    func testRowModelHumanizesEvents() {
        XCTAssertEqual(ActionRunRow.Model.humanizedEvent("workflow_dispatch"), "manual")
        XCTAssertEqual(ActionRunRow.Model.humanizedEvent("pull_request"), "pull request")
        XCTAssertEqual(ActionRunRow.Model.humanizedEvent("push"), "push")
    }

    func testReleaseRowModelFallsBackToTagWhenNameBlank() throws {
        let account = try Account(
            login: "octocat",
            avatarURL: nil,
            kind: .oauth,
            apiBaseURL: XCTUnwrap(URL(string: "https://api.github.com"))
        )
        let named = AccountRelease(
            account: account,
            repo: "octo/repo",
            release: .stub(tagName: "v2.0.0", name: "Big Bang")
        )
        XCTAssertEqual(ReleaseRow.Model(named).title, "Big Bang")

        let unnamed = AccountRelease(account: account, repo: "octo/repo", release: .stub(tagName: "v2.0.0", name: nil))
        XCTAssertEqual(ReleaseRow.Model(unnamed).title, "v2.0.0")
    }
}
