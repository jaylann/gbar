import Foundation
import ServiceManagement

/// The seam the store toggles login-item state through. A protocol (not the concrete
/// `LaunchAtLoginService`) so `AppStore` stays testable — a spy can record register/unregister
/// calls without touching `SMAppService` (which, in a unit-test bundle, would target the test
/// runner rather than the app).
@MainActor
protocol LaunchAtLoginManaging: AnyObject {
    /// Whether gbar is currently registered to launch at login.
    var isEnabled: Bool { get }
    /// Register (`true`) or unregister (`false`) gbar as a login item.
    func setEnabled(_ enabled: Bool) throws
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

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
