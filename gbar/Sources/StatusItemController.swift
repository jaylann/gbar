import AppKit
import SwiftUI

/// Owns the menu-bar status item in place of `MenuBarExtra`, which in `.window` style offers no
/// right-click menu and no access to the underlying `NSStatusItem`. Left-click toggles an
/// `NSPopover` hosting `MenuContentView`; right-click pops a Quit menu. The app stays an
/// `LSUIElement` agent (no Dock icon) exactly as it did under `MenuBarExtra`.
@MainActor
final class StatusItemController: NSObject, NSApplicationDelegate {
    /// The single app-wide store. Owned here (not in the SwiftUI `App`) so the popover and the
    /// `Settings` scene share one instance; `AppStore.init` self-starts polling.
    let store = AppStore()

    /// Owns the desktop-notification service and hands it to the store as its `notifier`, so the
    /// store can post banners without knowing about `UNUserNotificationCenter`. Both are `@MainActor`.
    private let notificationService = NotificationService()

    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    /// When the transient popover last auto-closed, used to swallow the reopen race (see below).
    private var lastPopoverClose: Date?

    private static let symbolName = "chevron.left.forwardslash.chevron.right"

    func applicationDidFinishLaunching(_: Notification) {
        // Wire up desktop notifications and request authorization at launch (not on first
        // menu-open), so banners can fire from a background poll before the user ever opens the
        // popover and the OS permission prompt appears at start.
        store.notifier = notificationService
        Task { await store.requestNotificationAuthorization() }

        let content = NSHostingController(
            rootView: MenuContentView(store: store) { [weak self] in self?.openSettings() }
        )
        // Let the SwiftUI content drive the popover size (mirrors the old MenuBarExtra window).
        content.sizingOptions = .preferredContentSize
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = content

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.imagePosition = .imageLeading
        item.button?.target = self
        item.button?.action = #selector(handleClick)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item

        observeBadge()
    }

    /// The status item — not a window — is what keeps this agent app alive. Without this, hiding
    /// the `SettingsOpener` window (our only `Window` scene) reads as "last window closed" and
    /// SwiftUI terminates the app right after launch.
    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        false
    }

    // MARK: Status-item button

    /// Re-render the button whenever `badgeCount` changes. `withObservationTracking` fires its
    /// `onChange` once, so re-register from there to keep following the `@Observable` store.
    private func observeBadge() {
        withObservationTracking {
            updateButton()
        } onChange: {
            Task { @MainActor [weak self] in self?.observeBadge() }
        }
    }

    private func updateButton() {
        // Read the tracked value first so `withObservationTracking` always registers the
        // dependency, even on a (currently unreachable) early return below.
        let count = store.badgeCount
        guard let button = statusItem?.button else { return }
        button.image = NSImage(systemSymbolName: Self.symbolName, accessibilityDescription: "gbar")
        button.title = count > 0 ? " \(count)" : ""
    }

    // MARK: Clicks

    @objc
    private func handleClick() {
        let event = NSApp.currentEvent
        // Treat control-click (ctrl + left) as a secondary click, per macOS convention.
        let isSecondary = event?.type == .rightMouseUp
            || (event?.type == .leftMouseUp && event?.modifierFlags.contains(.control) == true)
        if isSecondary {
            showMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        // The transient popover closes on the mouse-DOWN that precedes this action's mouse-UP, so
        // a click meant to dismiss it would otherwise immediately reopen it. Swallow a reopen that
        // lands right after that auto-close.
        if let closed = lastPopoverClose, Date().timeIntervalSince(closed) < 0.25 {
            lastPopoverClose = nil
            return
        }
        // Agent apps aren't active by default; activate so the popover's text fields (search)
        // can take keyboard focus.
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func showMenu() {
        guard let button = statusItem?.button else { return }
        // A transient menu shown on demand — assigning `statusItem.menu` would hijack left-click too.
        let menu = NSMenu()
        let quit = NSMenuItem(title: "Quit gbar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    // MARK: Settings

    /// Ask the SwiftUI side to open Settings. On macOS 14+ the Settings scene can only be opened
    /// from within the scene graph (`@Environment(\.openSettings)`), so route through the hidden
    /// `SettingsOpener` window rather than a now-defunct `showSettingsWindow:` selector.
    private func openSettings() {
        NotificationCenter.default.post(name: .gbarOpenSettings, object: nil)
    }
}

extension StatusItemController: NSPopoverDelegate {
    /// Stamp every close (transient auto-close included) so `togglePopover` can tell a
    /// dismiss-click apart from a fresh open.
    nonisolated func popoverDidClose(_: Notification) {
        MainActor.assumeIsolated { lastPopoverClose = Date() }
    }
}
