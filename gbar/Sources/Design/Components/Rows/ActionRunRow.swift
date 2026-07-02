import SwiftUI

/// A GitHub Actions workflow-run row. Reuses the check-row visual language (`CIStatusIndicator`
/// + mono branch + trailing duration) but surfaces signal the PR-scoped checks can't: the run's
/// trigger (push / schedule / manual dispatch) and runs on branches with no PR. Driven by a
/// local display model so the view stays free of the wire type.
struct ActionRunRow: View {
    struct Model: Identifiable {
        let id: String
        let repo: String
        /// The run's human title (commit / PR title), falling back to the workflow name.
        let title: String
        /// The workflow name (e.g. "CI"), shown in the meta line.
        let workflow: String
        let branch: String?
        /// Trigger event, humanized (e.g. "push", "schedule", "manual").
        let event: String
        let status: CIStatus
        let date: Date
        var duration: String?
    }

    let model: Model

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.sm) {
            CIStatusIndicator(status: model.status)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(model.title)
                    .font(Theme.Typography.rowTitle)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                metaLine
            }

            Spacer(minLength: Theme.Spacing.sm)

            if let duration = model.duration {
                Text(duration)
                    .font(Theme.Typography.mono)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var metaLine: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Text(model.repo)
            Text(model.workflow)
            if let branch = model.branch {
                Text("· \(branch)")
                    .font(Theme.Typography.mono)
                    .foregroundStyle(Theme.Palette.link)
            }
            Text("· \(model.event)")
            Text("· \(model.date.compactAgo())")
        }
        .font(Theme.Typography.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}

#if DEBUG
#Preview("ActionRunRow") {
    VStack(spacing: 2) {
        HoverRow {
            ActionRunRow(model: .init(
                id: "1",
                repo: "jaylann/gbar",
                title: "Fix keychain ACL prompt",
                workflow: "CI",
                branch: "stage",
                event: "push",
                status: .success,
                date: Date(timeIntervalSinceNow: -600),
                duration: "1m 42s"
            ))
        }
        HoverRow {
            ActionRunRow(model: .init(
                id: "2",
                repo: "jaylann/gbar",
                title: "Nightly",
                workflow: "Scheduled",
                branch: "main",
                event: "schedule",
                status: .failure,
                date: Date(timeIntervalSinceNow: -3600),
                duration: "3m 08s"
            ))
        }
        HoverRow(isFocused: true) {
            ActionRunRow(model: .init(
                id: "3",
                repo: "jaylann/gbar",
                title: "Release",
                workflow: "Release",
                branch: nil,
                event: "manual",
                status: .pending,
                date: Date(timeIntervalSinceNow: -60),
                duration: nil
            ))
        }
    }
    .padding(Theme.Spacing.sm)
    .frame(width: 400)
}
#endif
