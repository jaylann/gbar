import Foundation

/// Maps GitHub `CheckRun`s onto the design-system `CIStatus`/`CheckRow.Model` types. Kept
/// out of the model layer so `GitHubModels` stays free of UI/design dependencies, and out
/// of `AppStore` so the rules are unit-testable in isolation.
extension CheckRun {
    /// This run's status as a single `CIStatus`. A run that hasn't completed reads as
    /// pending; once completed the conclusion decides success/failure/neutral.
    var ciStatus: CIStatus {
        guard status == "completed" else { return .pending }
        switch conclusion {
        case "success": return .success
        case "action_required",
             "failure",
             "timed_out": return .failure
        case "cancelled",
             "neutral",
             "skipped": return .neutral
        default: return .neutral
        }
    }

    /// A `CheckRow.Model` for this run against a given repo/branch, deriving the duration
    /// string from the start/complete timestamps when both are present.
    func checkRowModel(repo: String, branch: String) -> CheckRow.Model {
        CheckRow.Model(
            id: String(id),
            repo: repo,
            branch: branch,
            workflow: name,
            status: ciStatus,
            duration: Self.duration(from: startedAt, to: completedAt)
        )
    }

    /// Compact `"1m 42s"` / `"12s"` duration, or nil unless both timestamps are present.
    private static func duration(from start: Date?, to end: Date?) -> String? {
        guard let start, let end else { return nil }
        let total = Int(max(0, end.timeIntervalSince(start)))
        let minutes = total / 60
        let seconds = total % 60
        return minutes > 0 ? "\(minutes)m \(seconds)s" : "\(seconds)s"
    }
}

extension [CheckRun] {
    /// Roll a set of check runs up into one overall `CIStatus`, or nil when there are none.
    /// Failure dominates, then pending. A green "passed" needs at least one genuinely successful
    /// run: an all-neutral set (every run skipped/cancelled/neutral) is not a pass, so it rolls up
    /// to `.neutral` — no green dot, and no spurious "CI passed" banner (which fires only on
    /// `.success`). A mix of success + neutral still passes. (`CheckRun.ciStatus` never yields
    /// `.error`, so it's not part of the rollup.)
    var ciRollup: CIStatus? {
        guard !isEmpty else { return nil }
        let statuses = map(\.ciStatus)
        if statuses.contains(.failure) { return .failure }
        if statuses.contains(.pending) { return .pending }
        guard statuses.contains(.success) else { return .neutral }
        return .success
    }
}
