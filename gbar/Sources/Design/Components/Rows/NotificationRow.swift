import SwiftUI

/// A notification-inbox row. GitHub's notifications feed isn't wired in v1, so this is
/// driven by a local display model — its shape mirrors what the `/notifications` API
/// returns, so wiring it later is a mapping, not a redesign. Timeline layout (Ivory-
/// style): type icon, subject title, dim reason · repo · time, unread dot.
struct NotificationRow: View {
    struct Model: Identifiable {
        enum Reason {
            case reviewRequested
            case mention
            case assigned
            case stateChange
            case commented

            var label: String {
                switch self {
                case .reviewRequested: "Review requested"
                case .mention: "Mentioned you"
                case .assigned: "Assigned to you"
                case .stateChange: "State changed"
                case .commented: "New comment"
                }
            }
        }

        let id: String
        let repo: String
        let title: String
        let reason: Reason
        let date: Date
        var isUnread: Bool
        var symbol = "bell"
        var isStarred = false
    }

    let model: Model

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.sm) {
            Image(systemName: model.symbol)
                .font(Theme.Typography.caption)
                .foregroundStyle(model.isUnread ? Theme.Palette.link : .secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(model.title)
                    .font(Theme.Typography.rowTitle.weight(model.isUnread ? .semibold : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                HStack(spacing: Theme.Spacing.xs) {
                    StarMarker(isStarred: model.isStarred)
                    Text(model.reason.label)
                    Text("· \(model.repo)").font(Theme.Typography.mono)
                    Text("· \(model.date.compactAgo())")
                }
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: Theme.Spacing.sm)
            if model.isUnread {
                UnseenDot(isUnseen: true)
            }
        }
    }
}

#if DEBUG
#Preview("NotificationRow") {
    VStack(spacing: 2) {
        HoverRow {
            NotificationRow(model: .init(
                id: "1",
                repo: "jaylann/gbar",
                title: "Add device-flow token refresh",
                reason: .reviewRequested,
                date: Date(timeIntervalSinceNow: -900),
                isUnread: true,
                symbol: "arrow.triangle.pull"
            ))
        }
        HoverRow {
            NotificationRow(model: .init(
                id: "2",
                repo: "jaylann/gbar",
                title: "Popover flickers on first open",
                reason: .mention,
                date: Date(timeIntervalSinceNow: -14400),
                isUnread: false,
                symbol: "smallcircle.filled.circle"
            ))
        }
    }
    .padding(Theme.Spacing.sm)
    .frame(width: 380)
}
#endif
