import SwiftUI

/// A compact search field: leading magnifier, a clear button once there's text. Auto-
/// focuses on open at the call site via `@FocusState` (`⌘F`). Note: inside a
/// non-activating menu-bar panel the field only receives keystrokes once the panel is
/// key — `MenuBarExtra(.window)` handles this, but a custom `NSPanel` must be made key
/// when this field focuses.
struct SearchField: View {
    var placeholder = "Search"
    @Binding var text: String
    var focus: FocusState<Bool>.Binding?

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            field
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .font(Theme.Typography.caption)
        .padding(.horizontal, Theme.Spacing.sm)
        .frame(height: 26)
        .background(Surface.controlFill, in: Capsule(style: .continuous))
    }

    @ViewBuilder
    private var field: some View {
        if let focus {
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .focused(focus)
        } else {
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
        }
    }
}

#if DEBUG
private struct SearchFieldPreview: View {
    @State private var empty = ""
    @State private var typed = "auth flow"
    var body: some View {
        VStack(spacing: Theme.Spacing.md) {
            SearchField(text: $empty)
            SearchField(placeholder: "Filter PRs", text: $typed)
        }
        .padding(Theme.Spacing.lg)
        .frame(width: 320)
    }
}

#Preview("SearchField") { SearchFieldPreview() }
#endif
