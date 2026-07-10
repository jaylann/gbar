import XCTest
@testable import gbar

final class CheckRunMappingTests: XCTestCase {
    // MARK: - CheckRun -> CIStatus

    func testStatusPendingWhenNotCompleted() {
        XCTAssertEqual(CheckRun.stub(status: "queued", conclusion: nil).ciStatus, .pending)
        XCTAssertEqual(CheckRun.stub(status: "in_progress", conclusion: nil).ciStatus, .pending)
        // Even a (spurious) conclusion doesn't count until the run has completed.
        XCTAssertEqual(CheckRun.stub(status: "in_progress", conclusion: "success").ciStatus, .pending)
    }

    func testStatusSuccess() {
        XCTAssertEqual(CheckRun.stub(status: "completed", conclusion: "success").ciStatus, .success)
    }

    func testStatusFailureConclusions() {
        for conclusion in ["failure", "timed_out", "action_required"] {
            XCTAssertEqual(
                CheckRun.stub(status: "completed", conclusion: conclusion).ciStatus,
                .failure,
                "expected \(conclusion) to map to .failure"
            )
        }
    }

    func testStatusNeutralConclusions() {
        for conclusion in ["neutral", "skipped", "cancelled"] {
            XCTAssertEqual(
                CheckRun.stub(status: "completed", conclusion: conclusion).ciStatus,
                .neutral,
                "expected \(conclusion) to map to .neutral"
            )
        }
    }

    func testStatusUnknownConclusionMapsToNeutral() {
        XCTAssertEqual(CheckRun.stub(status: "completed", conclusion: "stale").ciStatus, .neutral)
        XCTAssertEqual(CheckRun.stub(status: "completed", conclusion: nil).ciStatus, .neutral)
    }

    // MARK: - Rollup

    func testRollupEmptyIsNil() {
        XCTAssertNil([CheckRun]().ciRollup)
    }

    func testRollupFailureDominates() {
        let runs = [
            CheckRun.stub(id: 1, conclusion: "success"),
            CheckRun.stub(id: 2, status: "in_progress", conclusion: nil),
            CheckRun.stub(id: 3, conclusion: "failure"),
        ]
        XCTAssertEqual(runs.ciRollup, .failure)
    }

    func testRollupPendingBeatsSuccess() {
        let runs = [
            CheckRun.stub(id: 1, conclusion: "success"),
            CheckRun.stub(id: 2, status: "queued", conclusion: nil),
        ]
        XCTAssertEqual(runs.ciRollup, .pending)
    }

    func testRollupAllSuccess() {
        let runs = [
            CheckRun.stub(id: 1, conclusion: "success"),
            CheckRun.stub(id: 2, conclusion: "neutral"),
        ]
        XCTAssertEqual(runs.ciRollup, .success)
    }

    /// A set of only neutral runs (all skipped/cancelled/neutral) is NOT a pass: it must roll up to
    /// `.neutral`, not `.success` — otherwise the row shows a green dot and a spurious "CI passed"
    /// banner can fire on the pending→success transition.
    func testRollupAllNeutralIsNeutralNotSuccess() {
        for conclusion in ["neutral", "skipped", "cancelled"] {
            let runs = [
                CheckRun.stub(id: 1, conclusion: conclusion),
                CheckRun.stub(id: 2, conclusion: conclusion),
            ]
            XCTAssertEqual(runs.ciRollup, .neutral, "all-\(conclusion) must roll up to .neutral")
        }
    }

    // MARK: - CheckRow.Model mapping

    func testCheckRowModelMapsFields() {
        let model = CheckRun.stub(id: 7, name: "CI / build", conclusion: "success")
            .checkRowModel(repo: "octo/repo", branch: "abc1234")
        XCTAssertEqual(model.id, "7")
        XCTAssertEqual(model.repo, "octo/repo")
        XCTAssertEqual(model.branch, "abc1234")
        XCTAssertEqual(model.workflow, "CI / build")
        XCTAssertEqual(model.status, .success)
        // 00:00:00 -> 00:01:42 == 1m 42s
        XCTAssertEqual(model.duration, "1m 42s")
    }

    func testCheckRowModelDurationNilWhenTimestampsMissing() throws {
        let json = """
        {
          "id": 9,
          "name": "CI / lint",
          "status": "in_progress",
          "conclusion": null,
          "started_at": "2026-01-01T00:00:00Z",
          "completed_at": null
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let run = try decoder.decode(CheckRun.self, from: Data(json.utf8))
        XCTAssertNil(run.checkRowModel(repo: "octo/repo", branch: "x").duration)
    }
}
