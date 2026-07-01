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
        // `@Environment(\.openWindow)` resolves — the only reliable way to open the Settings
        // window from our AppKit status item. Must be declared *before* the Settings window.
        Window("", id: "gbar.settingsOpener") {
            SettingsOpener()
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 1, height: 1)

        // A plain `Window` (not a `Settings` scene) so `.hiddenTitleBar` applies: it drops the
        // vibrancy titlebar material that a `Settings` scene forces on and tints wallpaper-side,
        // letting `Surface.canvas` fill the whole window for one seamless surface. `⌘,` is lost
        // but irrelevant — this `LSUIElement` agent app opens Settings from the status item only.
        Window("gbar Settings", id: "gbar.settings") {
            SettingsView(store: appDelegate.store)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

/// Invisible helper living in the scene graph: hides its own window on launch, then opens the
/// Settings window whenever the status item posts `.gbarOpenSettings`. `WindowActivator` inside
/// `SettingsView` owns the focus + agent-demotion dance once the window appears.
private struct SettingsOpener: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .background(WindowHider())
            .onReceive(NotificationCenter.default.publisher(for: .gbarOpenSettings)) { _ in
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "gbar.settings")
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
