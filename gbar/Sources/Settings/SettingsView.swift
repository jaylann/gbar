import SwiftUI

/// Settings: manage connected accounts (add via device flow or PAT, each with an optional
/// host override for Enterprise; remove per account or all at once), tune the background
/// refresh cadence, and edit saved queries. See docs/PRODUCT.md.
struct SettingsView: View {
    @Bindable var store: AppStore
    @Environment(\.openURL) private var openURL

    @State private var clientID = AppConfig.bakedClientID ?? ""
    @State private var patToken = ""
    /// Optional per-account host override for the account being added (blank = default host).
    @State private var addHost = ""
    @State private var status = ""
    @State private var isWorking = false

    var body: some View {
        Form {
            accountsSection
            addAccountSection
            if store.isSignedIn {
                signOutAllSection
            }
            refreshSection
            if store.isSignedIn {
                SavedQueriesSection(store: store)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 460)
        // Owns the whole agent-app activation lifecycle for this window: promote to a
        // regular app + make the window key+main so its text fields accept clicks and
        // typing, then demote back to a no-Dock-icon agent when it actually closes.
        .background(WindowActivator())
    }

    private var accountsSection: some View {
        Section("Accounts") {
            if store.accounts.isEmpty {
                Text("No accounts connected yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.accounts) { account in
                    accountRow(account)
                }
            }
        }
    }

    private func accountRow(_ account: Account) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            Avatar(login: account.login, url: account.avatarImageURL, size: .medium)
            VStack(alignment: .leading, spacing: 1) {
                Text(account.login)
                Text(hostLabel(account.apiBaseURL))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(role: .destructive) {
                store.removeAccount(id: account.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Remove \(account.login)")
            .accessibilityLabel("Remove \(account.login)")
        }
    }

    private var addAccountSection: some View {
        Section("Add account") {
            TextField("Host (API base URL)", text: $addHost, prompt: Text(store.apiBaseURL.absoluteString))
                .textFieldStyle(.roundedBorder)
            Text(
                "Leave blank for the default host. Override for GitHub Enterprise, e.g. https://ghe.example.com/api/v3"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            TextField("OAuth App client ID", text: $clientID)
            Button("Sign in with GitHub") { Task { await startDeviceFlow() } }
                .disabled(clientID.isEmpty || isWorking)
            Divider()
            SecureField("…or paste a personal access token", text: $patToken)
            Button("Add token") { Task { await addToken() } }
                .disabled(patToken.isEmpty || isWorking)
            if !status.isEmpty {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var signOutAllSection: some View {
        Section {
            Button("Sign out of all accounts", role: .destructive) { store.signOutAll() }
        }
    }

    /// Short, human-readable host for an account's API base URL.
    private func hostLabel(_ url: URL) -> String {
        guard let host = url.host else { return url.absoluteString }
        return host == "api.github.com" ? "github.com" : host
    }

    /// The host a newly-added account should use: the override field if filled, else the
    /// app default. Falls back to the default on an unparseable override.
    private var resolvedAddURL: URL {
        let trimmed = addHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else { return store.apiBaseURL }
        return url
    }

    private func resetInputs() {
        patToken = ""
        addHost = ""
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

    private func startDeviceFlow() async {
        isWorking = true
        status = "Requesting a device code…"
        defer { isWorking = false }
        let host = resolvedAddURL
        let client = DeviceFlowClient(
            clientID: clientID,
            webBaseURL: AppConfig.webBaseURL(forAPI: host)
        )
        do {
            let code = try await client.requestDeviceCode(scopes: ["repo", "notifications"])
            status = "Enter code \(code.userCode) in the browser window…"
            if let url = URL(string: code.verificationURI) { openURL(url) }
            let token = try await client.pollForToken(code)
            try await store.addAccount(token: token, kind: .oauth, apiBaseURL: host)
            status = "Connected \(store.accounts.last.map { "@\($0.login)" } ?? "")."
            resetInputs()
        } catch {
            status = "Sign-in failed: \(error.localizedDescription)"
        }
    }

    private func addToken() async {
        isWorking = true
        status = "Validating token…"
        defer { isWorking = false }
        do {
            try await store.addAccount(token: patToken, kind: .personalAccessToken, apiBaseURL: resolvedAddURL)
            status = "Added \(store.accounts.last.map { "@\($0.login)" } ?? "")."
            resetInputs()
        } catch {
            status = "Couldn't add token: \(error.localizedDescription)"
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
