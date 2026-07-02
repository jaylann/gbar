import Foundation

/// Bridges the wire/store models for the per-repo feeds (`AccountActionRun`, `AccountRelease`)
/// to their design-system row models, keeping the display vocabulary in one place — mirrors
/// `NotificationMapping`.
extension ActionRunRow.Model {
    init(_ item: AccountActionRun, isStarred: Bool = false) {
        let run = item.run
        let title = run.displayTitle.flatMap { $0.isEmpty ? nil : $0 } ?? run.name
        self.init(
            id: item.id,
            repo: item.repo,
            title: title,
            workflow: run.name,
            branch: run.headBranch.flatMap { $0.isEmpty ? nil : $0 },
            event: Self.humanizedEvent(run.event),
            status: run.ciStatus,
            date: run.updatedAt,
            duration: run.durationText,
            isStarred: isStarred
        )
    }

    /// Humanize the Actions trigger event for the meta line. Unknown events pass through as-is.
    static func humanizedEvent(_ event: String) -> String {
        switch event {
        case "workflow_dispatch": "manual"
        case "pull_request",
             "pull_request_target": "pull request"
        case "workflow_run": "workflow"
        default: event
        }
    }
}

extension ReleaseRow.Model {
    init(_ item: AccountRelease, isStarred: Bool = false) {
        let release = item.release
        let title = release.name.flatMap { $0.isEmpty ? nil : $0 } ?? release.tagName
        self.init(
            id: item.id,
            repo: item.repo,
            title: title,
            tag: release.tagName,
            date: release.sortDate,
            isPrerelease: release.prerelease,
            isStarred: isStarred
        )
    }
}
