import SwiftUI

/// A quiet uppercase label above a group of rows, with an optional trailing count.
/// Deliberately low-contrast — groups should be separated by whitespace and these
/// headers, not by heavy dividers.
struct SectionHeader: View {
    let title: String
    var count: Int?

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Text(title.uppercased())
                .font(Theme.Typography.sectionLabel)
                .foregroundStyle(.tertiary)
                .kerning(0.4)
            if let count {
                CountBadge(count)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.top, Theme.Spacing.sm)
        .padding(.bottom, Theme.Spacing.xs)
    }
}

#if DEBUG
#Preview("SectionHeader") {
    VStack(alignment: .leading, spacing: 0) {
        SectionHeader(title: "Awaiting your review", count: 3)
        SectionHeader(title: "Your open PRs")
    }
    .frame(width: 380)
    .padding(.vertical, Theme.Spacing.sm)
}
#endif
