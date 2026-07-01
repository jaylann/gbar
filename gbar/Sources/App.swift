import SwiftUI

/// gbar — a GitHub companion in the macOS menu bar. `LSUIElement` (set in Info.plist)
/// makes this an agent app: menu-bar only, no dock icon, no main window.
@main
struct GbarApp: App {
    @State private var store = AppStore()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(store: store)
        } label: {
            if store.badgeCount > 0 {
                Label("\(store.badgeCount)", systemImage: "chevron.left.forwardslash.chevron.right")
            } else {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
            }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(store: store)
        }
    }
}
