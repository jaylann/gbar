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

    /// Register or unregister gbar as a login item. On success the observable mirror follows the
    /// request; on failure it re-syncs to the OS's actual state so the toggle snaps back to
    /// reality instead of showing a value the registration never reached.
    func setLaunchAtLogin(_ enabled: Bool) {
        guard let launchAtLogin else { return }
        do {
            try launchAtLogin.setEnabled(enabled)
            launchAtLoginEnabled = enabled
        } catch {
            let action = enabled ? "register" : "unregister"
            Log.store.error("launch-at-login \(action) failed: \(error.localizedDescription, privacy: .public)")
            launchAtLoginEnabled = launchAtLogin.isEnabled
        }
    }
}
