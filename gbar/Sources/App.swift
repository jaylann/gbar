import SwiftUI

/// gbar — a GitHub companion in the macOS menu bar. `LSUIElement` (set in Info.plist) makes this
/// an agent app: menu-bar only, no dock icon, no main window. The status item and its popover are
/// managed imperatively by `StatusItemController` (see there for why not `MenuBarExtra`); the only
/// SwiftUI scene left is `Settings`.
@main
struct GbarApp: App {
    @NSApplicationDelegateAdaptor(StatusItemController.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView(store: appDelegate.store)
        }
    }
}
