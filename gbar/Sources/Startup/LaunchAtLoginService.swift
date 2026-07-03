import Foundation
import ServiceManagement

/// The seam the store toggles login-item state through. A protocol (not the concrete
/// `LaunchAtLoginService`) so `AppStore` stays testable — a spy can record register/unregister
/// calls without touching `SMAppService` (which, in a unit-test bundle, would target the test
/// runner rather than the app).
@MainActor
protocol LaunchAtLoginManaging: AnyObject {
    /// Whether gbar is currently registered *and* enabled to launch at login.
    var isEnabled: Bool { get }
    /// True when gbar is registered but the user must enable it manually in System Settings
    /// (the OS's `.requiresApproval` state — reached after they previously disabled the item).
    /// A register call can't clear this; only the user can.
    var requiresApproval: Bool { get }
    /// Register (`true`) or unregister (`false`) gbar as a login item.
    func setEnabled(_ enabled: Bool) throws
    /// Open System Settings ▸ General ▸ Login Items, so a blocked user can enable gbar there.
    func openLoginItemsSettings()
}

/// Defaults so a test double only needs `isEnabled` + `setEnabled`; the live service overrides
/// the approval/settings hooks.
extension LaunchAtLoginManaging {
    var requiresApproval: Bool {
        false
    }

    func openLoginItemsSettings() {}
}

/// Thin `@MainActor` wrapper over `SMAppService.mainApp` (macOS 13+; the app targets 14). Needs
/// no helper bundle and no extra entitlement, and works in both the sandboxed (team-signed) and
/// non-sandboxed (ad-hoc) entitlement variants. The OS owns the state — the user can also flip it
/// in System Settings ▸ General ▸ Login Items — so callers read `isEnabled` live rather than
/// persisting their own copy.
@MainActor
final class LaunchAtLoginService: LaunchAtLoginManaging {
    var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    var requiresApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
