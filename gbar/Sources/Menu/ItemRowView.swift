import SwiftUI

/// A single PR/issue row in the menu.
struct ItemRowView: View {
    let item: SearchIssue

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbolName)
                .foregroundStyle(item.isPullRequest ? .green : .secondary)
                .font(.caption)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .lineLimit(1)
                    .font(.callout)
                HStack(spacing: 4) {
                    Text(item.repositorySlug)
                    Text("#\(item.number)")
                    if let login = item.user?.login {
                        Text("· \(login)")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    private var symbolName: String {
        if item.isPullRequest {
            return item.draft == true ? "circle.dotted" : "arrow.triangle.pull"
        }
        return "smallcircle.filled.circle"
    }
}
