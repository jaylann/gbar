import SwiftUI

extension Notification.Name {
    /// Posted by `StatusItemController` to ask the SwiftUI side to open the Settings scene.
    static let gbarOpenSettings = Notification.Name("gbar.openSettings")
}

/// gbar — a GitHub companion in the macOS menu bar. `LSUIElement` (set in Info.plist) makes this
/// an agent app: menu-bar only, no dock icon, no main window. The status item and its popover are
/// managed imperatively by `StatusItemController` (see there for why not `MenuBarExtra`).
@main
struct GbarApp: App {
    @NSApplicationDelegateAdaptor(StatusItemController.self) private var appDelegate

    var body: some Scene {
        // A tiny, permanently-hidden window that keeps a view in the scene graph so
        // `@Environment(\.openSettings)` resolves — the only reliable way to open the Settings
        // scene from our AppKit status item on macOS 14+, where the old `showSettingsWindow:`
        // selector no longer works. Must be declared *before* `Settings`.
        Window("", id: "gbar.settingsOpener") {
            SettingsOpener()
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 1, height: 1)

        Settings {
            SettingsView(store: appDelegate.store)
        }
    }
}

/// Invisible helper living in the scene graph: hides its own window on launch, then opens Settings
/// whenever the status item posts `.gbarOpenSettings`. `WindowActivator` inside `SettingsView` owns
/// the focus + agent-demotion dance once the window appears.
private struct SettingsOpener: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .background(WindowHider())
            .onReceive(NotificationCenter.default.publisher(for: .gbarOpenSettings)) { _ in
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
    }
}

/// Neutralizes the opener's host window so the scene stays alive (feeding `SettingsOpener`)
/// without ever showing a stray window: transparent, offscreen, non-interactive, ordered out,
/// and excluded from state restoration so macOS can't resurrect it visible on the next launch.
private struct WindowHider: NSViewRepresentable {
    func makeNSView(context _: Context) -> NSView {
        let view = NSView()
        Task { @MainActor in Self.hide(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context _: Context) {
        Self.hide(nsView.window)
    }

    @MainActor
    private static func hide(_ window: NSWindow?) {
        guard let window else { return }
        window.isRestorable = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderOut(nil)
    }
}
