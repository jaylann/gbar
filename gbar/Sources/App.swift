import SwiftUI

/// gbar — a GitHub companion in the macOS menu bar. `LSUIElement` (set in Info.plist)
/// makes this an agent app: menu-bar only, no dock icon, no main window.
@main
struct GbarApp: App {
    @State private var store = AppStore()

    var body: some Scene {
        MenuBarExtra("gbar", systemImage: "chevron.left.forwardslash.chevron.right") {
            MenuContentView(store: store)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(store: store)
        }
    }
}
