import SwiftUI

/// Settings, rebuilt on the app's own design system instead of a native grouped `Form`: a
/// compact header with the popover's `InlineTabBar` switching between three focused panes —
/// **Accounts** (add via device flow or PAT, per-account Enterprise host, remove one or all),
/// **Queries** (edit the menu's saved-search sections), and **General** (background refresh
/// cadence, notification preferences, build info). See docs/PRODUCT.md.
///
/// Hosted in a `.hiddenTitleBar` `Window` (not a `Settings` scene) so `Surface.canvas` fills the
/// whole window as one seamless surface — the traffic lights float in the `titlebarInset` strip.
struct SettingsView: View {
    @Bindable var store: AppStore

    @State private var tab: Tab = .accounts

    private enum Tab: Hashable {
        case accounts
        case queries
        case watchlist
        case general
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            pane
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(width: 500, height: 560)
        .background(Surface.canvas)
        // Owns the whole agent-app activation lifecycle for this window: promote to a
        // regular app + make the window key+main so its text fields accept clicks and
        // typing, then demote back to a no-Dock-icon agent when it actually closes.
        .background(WindowActivator())
    }

    /// Left-aligned tabs, the same `InlineTabBar` the popover header uses.
    private var header: some View {
        HStack {
            InlineTabBar(tabs: tabs, selection: $tab)
            Spacer(minLength: 0)
        }
        // Below the reserved titlebar band (safe area), the tab bar hugs it: left-aligned,
        // no top gap, so it reads as one surface with the traffic-light strip above.
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.bottom, Theme.Spacing.sm)
    }

    /// Counts ride quietly beside the labels (hidden at zero) so the tab bar doubles as a
    /// glance at how many accounts and saved queries are configured.
    private var tabs: [InlineTabBar<Tab>.Tab] {
        [
            .init(tag: .accounts, title: "Accounts", count: store.accounts.isEmpty ? nil : store.accounts.count),
            .init(tag: .queries, title: "Queries", count: store.savedQueries.isEmpty ? nil : store.savedQueries.count),
            .init(tag: .watchlist, title: "Watchlist", count: store.watchlist.isEmpty ? nil : store.watchlist.count),
            .init(tag: .general, title: "General"),
        ]
    }

    @ViewBuilder
    private var pane: some View {
        switch tab {
        case .accounts: AccountsPane(store: store)
        case .queries: QueriesPane(store: store)
        case .watchlist: WatchlistPane(store: store)
        case .general: GeneralPane(store: store)
        }
    }
}

/// Makes a window opened from an `LSUIElement` agent app usable. Such a window can
/// become key (Tab works) but not *main*, so mouse clicks don't move first responder
/// into a text field. This captures the real hosting `NSWindow`, promotes the app to
/// `.regular` and forces the window key+main so click-to-focus works. The reverse — dropping
/// the Dock icon back to `.accessory` — lives in `StatusItemController`'s
/// `applicationShouldTerminateAfterLastWindowClosed`, the only spot where the switch actually
/// takes effect (from here, mid-close and still frontmost, AppKit ignores it).
private struct WindowActivator: NSViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context _: Context) -> NSView {
        NSView()
    }

    /// The hosting window isn't attached in `makeNSView`, but it is by the time SwiftUI
    /// runs an update pass — so grab it here (idempotent via the coordinator's guard).
    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.activateIfNeeded(nsView)
    }

    @MainActor
    final class Coordinator {
        private var didActivate = false
        private var willCloseToken: (any NSObjectProtocol)?

        func activateIfNeeded(_ view: NSView) {
            guard !didActivate, let window = view.window else { return }
            didActivate = true
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            // The hidden titlebar removes the usual drag handle; let the canvas move the window.
            window.isMovableByWindowBackground = true
            // Don't let macOS restore this window (visible, with a Dock icon) on next launch —
            // it's only ever meant to appear on an explicit status-item request.
            window.isRestorable = false
            window.makeKeyAndOrderFront(nil)
            // Re-arm this one-time setup for the next open: clear `didActivate` on close so a
            // reopen re-runs the key+main promotion (a surviving coordinator would otherwise skip
            // it). A block-based observer isn't freed when its `object` deallocates, so unregister
            // it once it fires. The Dock demotion is handled by the app delegate, not here.
            willCloseToken = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.didActivate = false
                    self?.removeWillCloseObserver()
                }
            }
        }

        private func removeWillCloseObserver() {
            willCloseToken.map(NotificationCenter.default.removeObserver)
            willCloseToken = nil
        }
    }
}

#if DEBUG
#Preview("Settings") {
    SettingsView(store: AppStore())
}
#endif
