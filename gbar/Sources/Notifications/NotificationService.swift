import AppKit
import Foundation
import UserNotifications

/// App-level projection of `UNAuthorizationStatus` — only the states the Settings UI
/// distinguishes. Keeps `UserNotifications` out of the store and views.
enum NotificationAuthStatus: Equatable {
    case notDetermined
    case denied
    case authorized

    init(_ status: UNAuthorizationStatus) {
        switch status {
        case .notDetermined: self = .notDetermined
        case .denied: self = .denied
        default: self = .authorized // .authorized, .provisional, .ephemeral
        }
    }
}

/// The seam the store posts through. A protocol (not the concrete `NotificationService`) so
/// `AppStore` stays testable — a spy can record posts without touching
/// `UNUserNotificationCenter`.
@MainActor
protocol DesktopNotifying: AnyObject {
    func post(title: String, body: String, url: URL?)
    @discardableResult
    func requestAuthorization() async -> Bool
    func authorizationStatus() async -> NotificationAuthStatus
}

/// Defaults so simple test doubles only need `post`; the real service overrides both.
extension DesktopNotifying {
    @discardableResult
    func requestAuthorization() async -> Bool {
        true
    }

    func authorizationStatus() async -> NotificationAuthStatus {
        .authorized
    }
}

/// Thin `@MainActor` wrapper over `UNUserNotificationCenter`: requests authorization, posts
/// native banners, and opens a notification's deep-link URL when the user clicks it. The
/// delegate callbacks arrive off the main actor, so they hop back via `Task { @MainActor }`.
@MainActor
final class NotificationService: NSObject, DesktopNotifying {
    /// `userInfo` key carrying the notification's deep-link (a browser URL string).
    /// `nonisolated` so the off-main-actor delegate callback can read it.
    private nonisolated static let urlKey = "url"

    private let center = UNUserNotificationCenter.current()

    override init() {
        super.init()
        center.delegate = self
    }

    /// Ask the OS for permission to post notifications. Best-effort: a denial or error just
    /// means no banners fire — the rest of the app is unaffected. Safe to call on every launch.
    @discardableResult
    func requestAuthorization() async -> Bool {
        do {
            // Call on a fresh `.current()` (a disconnected region) rather than the main-actor
            // stored `center`: awaiting a non-Sendable stored reference trips Swift 6.0's
            // "sending 'self.center' risks data races" (Xcode 16.4); the local doesn't.
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
            if !granted {
                Log.notifications.info("authorization not granted — banners will not fire")
            }
            return granted
        } catch {
            Log.notifications.error("authorization request failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// The OS-level authorization state, so the Settings pane can surface a denial instead of
    /// posts silently no-oping. Same local-`.current()` workaround as `requestAuthorization`.
    func authorizationStatus() async -> NotificationAuthStatus {
        await NotificationAuthStatus(Self.currentAuthorizationStatus())
    }

    /// Reads the settings in a nonisolated region and returns only the Sendable status —
    /// awaiting the non-Sendable `UNNotificationSettings` into the main actor trips Swift
    /// 6.0's region checker (Xcode 16.4) even though 6.2 accepts it.
    private nonisolated static func currentAuthorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// Post a banner immediately. `url` (if any) rides along in `userInfo` so a click can
    /// deep-link to the item in the browser.
    func post(title: String, body: String, url: URL?) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let url {
            content.userInfo = [Self.urlKey: url.absoluteString]
        }
        // `trigger: nil` delivers right away; a random identifier avoids coalescing distinct
        // events into one banner.
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(request) { error in
            if let error {
                Log.notifications.error("post failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

extension NotificationService: UNUserNotificationCenterDelegate {
    /// Show the banner even while gbar is frontmost (rare for a menu-bar agent, but the
    /// Settings window counts as frontmost).
    nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter,
        willPresent _: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    /// On click, open the stashed deep-link in the default browser. `urlString` is a `Sendable`
    /// value, so it's safe to carry across the actor hop; the completion handler is called
    /// synchronously first so the system isn't left waiting on the main actor.
    nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let urlString = response.notification.request.content.userInfo[Self.urlKey] as? String
        completionHandler()
        // Only ever hand an http(s) link to NSWorkspace — a hostile host must not be able to open
        // a local file or launch an app via a `file:`/custom-scheme deep link.
        guard let url = WebLink.parse(urlString) else { return }
        Task { @MainActor in
            NSWorkspace.shared.open(url)
        }
    }
}
