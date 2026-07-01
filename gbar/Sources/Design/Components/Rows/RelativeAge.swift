import Foundation

extension Date {
    /// Compact "time ago" for row metadata: `now`, `5m`, `3h`, `2d`, `6w`, `1y`.
    /// Tighter than `RelativeDateTimeFormatter` so it fits a dense meta line.
    func compactAgo(relativeTo now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(self))
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(Int(seconds / 60))m"
        case ..<86400: return "\(Int(seconds / 3600))h"
        case ..<604_800: return "\(Int(seconds / 86400))d"
        case ..<2_629_800: return "\(Int(seconds / 604_800))w"
        case ..<31_557_600: return "\(Int(seconds / 2_629_800))mo"
        default: return "\(Int(seconds / 31_557_600))y"
        }
    }
}
