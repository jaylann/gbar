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

    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    /// When the transient popover last auto-closed, used to swallow the reopen race (see below).
    private var lastPopoverClose: Date?

    private static let symbolName = "chevron.left.forwardslash.chevron.right"

    func applicationDidFinishLaunching(_: Notification) {
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

    /// Open the SwiftUI `Settings` scene from AppKit. `WindowActivator` inside `SettingsView` owns
    /// the focus + agent-demotion dance once the window appears, however Settings is opened.
    private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
}

extension StatusItemController: NSPopoverDelegate {
    /// Stamp every close (transient auto-close included) so `togglePopover` can tell a
    /// dismiss-click apart from a fresh open.
    nonisolated func popoverDidClose(_: Notification) {
        MainActor.assumeIsolated { lastPopoverClose = Date() }
    }
}
