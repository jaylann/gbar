import Foundation

// MARK: - Launch at login

extension AppStore {
    /// Re-read the OS login-item state and publish it for the Settings UI. No-op when no service
    /// is wired (tests/previews without one). Called at launch and when gbar regains focus, so a
    /// change made in System Settings ▸ General ▸ Login Items is reflected in the toggle.
    func refreshLaunchAtLoginStatus() {
        guard let launchAtLogin else { return }
        launchAtLoginEnabled = launchAtLogin.isEnabled
    }

    /// Register or unregister gbar as a login item, then mirror the OS's *actual* resulting state
    /// (never the requested value) so the toggle can't show something the OS didn't reach. If an
    /// enable is blocked because the user previously disabled gbar in Login Items
    /// (`.requiresApproval` — a register call can't clear it), send them there to flip it on
    /// rather than leaving the toggle silently snapped off.
    func setLaunchAtLogin(_ enabled: Bool) {
        guard let launchAtLogin else { return }
        do {
            try launchAtLogin.setEnabled(enabled)
        } catch {
            let action = enabled ? "register" : "unregister"
            Log.store.error("launch-at-login \(action) failed: \(error.localizedDescription, privacy: .public)")
        }
        launchAtLoginEnabled = launchAtLogin.isEnabled
        if enabled, !launchAtLoginEnabled, launchAtLogin.requiresApproval {
            launchAtLogin.openLoginItemsSettings()
        }
    }
}
