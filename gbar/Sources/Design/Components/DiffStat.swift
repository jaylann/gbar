import SwiftUI

/// The `+42 −7` line-count stat, in mono so the columns don't jitter. Additions in
/// the open/green tone, deletions in the closed/red tone — the same semantic colors
/// used everywhere else.
struct DiffStat: View {
    let additions: Int
    let deletions: Int

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Text("+\(additions)")
                .foregroundStyle(Theme.Palette.open)
            Text("−\(deletions)")
                .foregroundStyle(Theme.Palette.closed)
        }
        .font(Theme.Typography.mono)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(additions) additions, \(deletions) deletions")
    }
}

#if DEBUG
#Preview("DiffStat") {
    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
        DiffStat(additions: 42, deletions: 7)
        DiffStat(additions: 3, deletions: 0)
        DiffStat(additions: 1024, deletions: 512)
    }
    .padding(Theme.Spacing.xl)
}
#endif
