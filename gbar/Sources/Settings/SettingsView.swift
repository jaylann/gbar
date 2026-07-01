import SwiftUI

/// Settings: connect an account (device flow or PAT), tune the background refresh cadence,
/// and point gbar at a GitHub host. Deeper preferences (saved queries, notifications) attach
/// here as the app grows. See docs/PRODUCT.md.
struct SettingsView: View {
    @Bindable var store: AppStore
    @Environment(\.openURL) private var openURL

    @State private var clientID = AppConfig.bakedClientID ?? ""
    @State private var patToken = ""
    @State private var status = ""
    @State private var isWorking = false

    var body: some View {
        Form {
            accountSection
            refreshSection
            advancedSection
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 420)
        // Owns the whole agent-app activation lifecycle for this window: promote to a
        // regular app + make the window key+main so its text fields accept clicks and
        // typing, then demote back to a no-Dock-icon agent when it actually closes.
        .background(WindowActivator())
    }

    private var accountSection: some View {
        Section("Account") {
            if store.isSignedIn {
                LabeledContent("Status", value: "Connected")
                Button("Sign out", role: .destructive) { store.signOut() }
            } else {
                TextField("OAuth App client ID", text: $clientID)
                Button("Sign in with GitHub") { Task { await startDeviceFlow() } }
                    .disabled(clientID.isEmpty || isWorking)
                Divider()
                SecureField("…or paste a personal access token", text: $patToken)
                Button("Use token") {
                    store.signIn(token: patToken, kind: .personalAccessToken)
                    patToken = ""
                }
                .disabled(patToken.isEmpty)
            }
            if !status.isEmpty {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var refreshSection: some View {
        Section("Refresh") {
            Picker("Auto-refresh", selection: pollIntervalBinding) {
                ForEach(PollInterval.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            Text("How often gbar checks GitHub in the background — keeps the badge current while the menu is closed.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var pollIntervalBinding: Binding<PollInterval> {
        Binding(
            get: { PollInterval(rawValue: store.pollInterval) ?? .m1 },
            set: { store.pollInterval = $0.rawValue }
        )
    }

    private var advancedSection: some View {
        Section("Advanced") {
            TextField("API base URL", text: apiBaseBinding)
                .textFieldStyle(.roundedBorder)
            Text("Override for GitHub Enterprise, e.g. https://ghe.example.com/api/v3")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var apiBaseBinding: Binding<String> {
        Binding(
            get: { store.apiBaseURL.absoluteString },
            set: { if let url = URL(string: $0) { store.apiBaseURL = url } }
        )
    }

    private func startDeviceFlow() async {
        isWorking = true
        status = "Requesting a device code…"
        defer { isWorking = false }
        let client = DeviceFlowClient(
            clientID: clientID,
            webBaseURL: AppConfig.webBaseURL(forAPI: store.apiBaseURL)
        )
        do {
            let code = try await client.requestDeviceCode(scopes: ["repo", "notifications"])
            status = "Enter code \(code.userCode) in the browser window…"
            if let url = URL(string: code.verificationURI) { openURL(url) }
            let token = try await client.pollForToken(code)
            store.signIn(token: token, kind: .oauth)
            status = "Connected."
        } catch {
            status = "Sign-in failed: \(error.localizedDescription)"
        }
    }
}

/// Makes a window opened from an `LSUIElement` agent app usable. Such a window can
/// become key (Tab works) but not *main*, so mouse clicks don't move first responder
/// into a text field. This captures the real hosting `NSWindow`, promotes the app to
/// `.regular` and forces the window key+main so click-to-focus works, then demotes back
/// to `.accessory` (no Dock icon) when that window actually closes — a concrete
/// `willClose` signal rather than a possibly-missed SwiftUI `onDisappear`.
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

        func activateIfNeeded(_ view: NSView) {
            guard !didActivate, let window = view.window else { return }
            didActivate = true
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            // Scoped to this window's close; the token needs no cleanup because the
            // observation dies with the window it's bound to.
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { _ in
                MainActor.assumeIsolated { _ = NSApp.setActivationPolicy(.accessory) }
            }
        }
    }
}
