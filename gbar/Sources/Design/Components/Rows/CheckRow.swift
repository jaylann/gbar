import SwiftUI

/// A CI check-run row. Per-check status isn't wired in v1, so this is driven by a
/// local display model shaped like a GitHub check run. Branch names and durations use
/// mono — the single choice that makes the app read as a dev tool.
struct CheckRow: View {
    struct Model: Identifiable {
        let id: String
        let repo: String
        let branch: String
        let workflow: String
        let status: CIStatus
        var duration: String?
    }

    let model: Model

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.sm) {
            CIStatusIndicator(status: model.status)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(model.workflow)
                    .font(Theme.Typography.rowTitle)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                HStack(spacing: Theme.Spacing.xs) {
                    Text(model.repo)
                    Text(model.branch)
                        .font(Theme.Typography.mono)
                        .foregroundStyle(Theme.Palette.link)
                }
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: Theme.Spacing.sm)

            if let duration = model.duration {
                Text(duration)
                    .font(Theme.Typography.mono)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#if DEBUG
#Preview("CheckRow") {
    VStack(spacing: 2) {
        HoverRow {
            CheckRow(model: .init(
                id: "1",
                repo: "jaylann/gbar",
                branch: "feature/design-system",
                workflow: "CI / build-and-test",
                status: .success,
                duration: "1m 42s"
            ))
        }
        HoverRow {
            CheckRow(model: .init(
                id: "2",
                repo: "jaylann/gbar",
                branch: "stage",
                workflow: "CI / lint",
                status: .pending,
                duration: nil
            ))
        }
        HoverRow(isFocused: true) {
            CheckRow(model: .init(
                id: "3",
                repo: "jaylann/gbar",
                branch: "fix/keychain",
                workflow: "CI / typos",
                status: .failure,
                duration: "12s"
            ))
        }
    }
    .padding(Theme.Spacing.sm)
    .frame(width: 380)
}
#endif
