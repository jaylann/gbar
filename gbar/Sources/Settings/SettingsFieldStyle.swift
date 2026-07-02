import SwiftUI

/// A plain field restyled to sit on the design system: quiet fill, small radius, matching the
/// height of `GBButtonStyle`. Shared by the Settings panes' text inputs; not a global component.
struct SettingsFieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(Theme.Typography.caption)
            .padding(.horizontal, Theme.Spacing.md)
            .frame(height: 28)
            .background(Surface.controlFill, in: Capsule(style: .continuous))
    }
}

/// One-line inline validation caption under a field. `warning` uses the pending amber for
/// fixable input problems; `error` uses the closed red for hard failures.
struct ValidationHint: View {
    enum Severity {
        case warning
        case error
    }

    let message: String
    var severity: Severity = .warning

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(Theme.Typography.caption)
            .foregroundStyle(severity == .warning ? Theme.Palette.pending : Theme.Palette.closed)
            .fixedSize(horizontal: false, vertical: true)
    }
}
