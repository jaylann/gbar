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

    /// Manages gbar's macOS login-item registration and hands it to the store, so the store can
    /// toggle "Launch at login" without importing `ServiceManagement`. `@MainActor` like the store.
    private let launchAtLoginService = LaunchAtLoginService()

    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    /// Outside-click / app-resign monitors, live only while the popover is shown. Installed in
    /// `showPopover`, torn down in `popoverDidClose` (so every close path cleans up exactly once).
    private var eventMonitors: [Any] = []

    private static let symbolName = "chevron.left.forwardslash.chevron.right"

    func applicationDidFinishLaunching(_: Notification) {
        // Wire up desktop notifications and request authorization at launch (not on first
        // menu-open), so banners can fire from a background poll before the user ever opens the
        // popover and the OS permission prompt appears at start.
        store.notifier = notificationService
        Task { await store.requestNotificationAuthorization() }

        // Wire up login-item management and read the current registration so the Settings toggle
        // reflects reality from the first open.
        store.launchAtLogin = launchAtLoginService
        store.refreshLaunchAtLoginStatus()

        let content = NSHostingController(
            rootView: MenuContentView(store: store) { [weak self] in self?.openSettings() }
        )
        // Let the SwiftUI content drive the popover size (mirrors the old MenuBarExtra window).
        content.sizingOptions = .preferredContentSize
        // `.applicationDefined` (not `.transient`): AppKit does no automatic closing, so the
        // dismiss-click on the status button no longer auto-closes on mouse-DOWN and then races
        // the mouse-UP reopen. We drive open/close deterministically and reimplement outside-click
        // dismissal with our own event monitors (see `installEventMonitors`).
        popover.behavior = .applicationDefined
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

    /// The status item — not a window — is what keeps this agent app alive. Without returning
    /// `false`, hiding the `SettingsOpener` window (our only `Window` scene) reads as "last window
    /// closed" and SwiftUI terminates the app right after launch.
    ///
    /// This is also the reliable place to drop the Dock icon back to `.accessory`: it fires when the
    /// last visible window (Settings) closes — at launch when the opener hides, and every time the
    /// Settings window closes — with the app mid-transition so the switch actually takes effect. The
    /// same call from the window's `willClose` (app still frontmost) is silently ignored, leaving the
    /// icon stranded in the Dock. Promotion to `.regular` stays on the explicit open-Settings path.
    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        NSApp.setActivationPolicy(.accessory)
        return false
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
        // Read the tracked values first so `withObservationTracking` always registers both
        // dependencies, even on a (currently unreachable) early return below.
        let count = store.badgeCount
        let tooltip = store.badgeTooltip
        guard let button = statusItem?.button else { return }
        // The bare number is cryptic on its own, so the hover tooltip (and VoiceOver label)
        // spell out what it counts — e.g. "12 PRs awaiting your review".
        button.image = NSImage(systemSymbolName: Self.symbolName, accessibilityDescription: tooltip)
        button.title = count > 0 ? " \(count)" : ""
        button.toolTip = tooltip
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
            closePopover()
        } else {
            showPopover(from: button)
        }
    }

    private func showPopover(from button: NSStatusBarButton) {
        // Show BEFORE activating. `show` anchors to the status button's window, which lives on the
        // display the user just clicked. Activating first can promote another window (e.g. Settings
        // on a second display) to main and drag placement to that display; making the popover key
        // first pins it, so the later `activate` can't move it. Activation is still needed so the
        // popover's SwiftUI search field can take keyboard focus in this LSUIElement agent app.
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        installEventMonitors()
    }

    private func closePopover() {
        guard popover.isShown else { return }
        popover.performClose(nil) // monitors torn down in `popoverDidClose`
    }

    // MARK: Outside-click dismissal

    /// `.applicationDefined` gives no automatic dismissal, so reimplement it: a global monitor for
    /// clicks in other apps, a local monitor for clicks on our own other windows (Settings), and an
    /// app-resign observer for Cmd-Tab / Spaces switches that emit no catchable mouse-down.
    private func installEventMonitors() {
        removeEventMonitors() // defensive: never double-install
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        // Fires only for clicks delivered to other apps — never our button or popover — so any
        // firing is unambiguously "clicked away".
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.closePopover() }
        }) {
            eventMonitors.append(global)
        }
        // Fires for our own events; must not swallow them and must ignore clicks inside the popover
        // or on the status button.
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handleLocalMouseDown() }
            return event // never swallow — the click must reach its target
        }) {
            eventMonitors.append(local)
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidResignActive),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
    }

    private func removeEventMonitors() {
        for monitor in eventMonitors {
            NSEvent.removeMonitor(monitor)
        }
        eventMonitors.removeAll()
        NotificationCenter.default.removeObserver(
            self, name: NSApplication.didResignActiveNotification, object: nil
        )
    }

    /// Geometric outside-click test in screen coordinates. Status-bar clicks often arrive with a
    /// nil `event.window`, so a window-identity test is unreliable; compare mouse location against
    /// the popover and button window frames instead.
    private func handleLocalMouseDown() {
        let point = NSEvent.mouseLocation
        if let popWin = popover.contentViewController?.view.window, popWin.frame.contains(point) { return }
        if let btnWin = statusItem?.button?.window, btnWin.frame.contains(point) { return }
        closePopover()
    }

    @objc
    private func appDidResignActive() {
        closePopover()
    }

    private func showMenu() {
        guard let button = statusItem?.button else { return }
        // Dismiss the popover first so the Quit menu doesn't pop up over a still-open panel.
        closePopover()
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
    /// Tear down the outside-click monitors on every close path (button toggle, monitor, resign).
    nonisolated func popoverDidClose(_: Notification) {
        MainActor.assumeIsolated { removeEventMonitors() }
    }
}
