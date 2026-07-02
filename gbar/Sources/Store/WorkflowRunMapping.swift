import Foundation

/// Maps GitHub `WorkflowRun`s onto the design-system `CIStatus` and a compact duration string.
/// Kept out of the model layer so `GitHubModels` stays free of UI/design dependencies, and out
/// of `AppStore` so the rules are unit-testable in isolation — mirroring `CheckRunMapping`.
extension WorkflowRun {
    /// This run's status as a single `CIStatus`. A run that hasn't completed reads as pending;
    /// once completed the conclusion decides success/failure/neutral. The conclusion vocabulary
    /// is a superset of check runs' (adds `startup_failure`/`stale`), so it's mapped explicitly.
    var ciStatus: CIStatus {
        guard status == "completed" else { return .pending }
        switch conclusion {
        case "success": return .success
        case "action_required",
             "failure",
             "startup_failure",
             "timed_out": return .failure
        case "cancelled",
             "neutral",
             "skipped",
             "stale": return .neutral
        default: return .neutral
        }
    }

    /// Compact `"1m 42s"` / `"12s"` run duration, or nil until the run has both a start and an
    /// end. Prefers `runStartedAt` (when execution began) over `createdAt` (when queued).
    var durationText: String? {
        guard status == "completed" else { return nil }
        let start = runStartedAt ?? createdAt
        return Self.duration(from: start, to: updatedAt)
    }

    private static func duration(from start: Date, to end: Date) -> String {
        let total = Int(max(0, end.timeIntervalSince(start)))
        let minutes = total / 60
        let seconds = total % 60
        return minutes > 0 ? "\(minutes)m \(seconds)s" : "\(seconds)s"
    }
}
