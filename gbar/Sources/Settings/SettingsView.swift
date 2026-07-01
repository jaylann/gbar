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
    /// Typed sign-in state, rendered as a loading / error / success line under the add-account
    /// controls. Replaces the old free-form status string so failures read as actionable copy.
    @State private var status: AuthStatus = .idle
    /// Which entry last ran, so the failure state's "Try again" re-runs the right one.
    @State private var lastAttempt: AuthAttempt?

    /// Typed sign-in status backing the add-account section's inline feedback.
    private enum AuthStatus: Equatable {
        case idle
        case working(String)
        case failure(String)
        case success(String)

        var isWorking: Bool {
            if case .working = self { true } else { false }
        }
    }

    /// The add-account entry point a user last used — drives the failure-state retry.
    private enum AuthAttempt {
        case deviceFlow
        case pat
    }

    var body: some View {
        Form {
            accountsSection
            addAccountSection
            if store.isSignedIn {
                signOutAllSection
            }
            refreshSection
            notificationsSection
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
            Button("Sign in with GitHub") {
                lastAttempt = .deviceFlow
                Task { await startDeviceFlow() }
            }
            .disabled(clientID.isEmpty || status.isWorking)
            Divider()
            SecureField("…or paste a personal access token", text: $patToken)
            Button("Add token") {
                lastAttempt = .pat
                Task { await addToken() }
            }
            .disabled(patToken.isEmpty || status.isWorking)
            statusView
        }
    }

    /// Inline sign-in feedback: a spinner while working, a red actionable error with a retry
    /// affordance on failure, or a green confirmation on success.
    @ViewBuilder
    private var statusView: some View {
        switch status {
        case .idle:
            EmptyView()
        case let .working(message):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(message)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        case let .failure(message):
            VStack(alignment: .leading, spacing: 6) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                Button("Try again") { retry() }
                    .controlSize(.small)
                    .disabled(status.isWorking)
            }
        case let .success(message):
            Label(message, systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
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
    /// app default. Falls back to the default on an unparsable override.
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

    private var notificationsSection: some View {
        Section("Notifications") {
            Toggle("Enable notifications", isOn: $store.notificationsEnabled)
            Group {
                Toggle("New notifications", isOn: $store.notifyInbox)
                Toggle("New PRs & issues", isOn: $store.notifySections)
                Toggle("CI status changes", isOn: $store.notifyChecks)
            }
            .disabled(!store.notificationsEnabled)
            Text("Native banners for new items and CI pass/fail on your PRs. Click one to open it in the browser.")
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
        status = .working("Requesting a device code…")
        let host = resolvedAddURL
        // Persist the (public) client ID on the store so a later 401 can reconnect this account
        // in place without the user re-entering it.
        store.oauthClientID = clientID
        let client = DeviceFlowClient(
            clientID: clientID,
            webBaseURL: AppConfig.webBaseURL(forAPI: host)
        )
        do {
            let code = try await client.requestDeviceCode(scopes: DeviceFlowClient.defaultScopes)
            status = .working("Enter code \(code.userCode) in the browser window…")
            if let url = URL(string: code.verificationURI) { openURL(url) }
            let token = try await client.pollForToken(code)
            try await store.addAccount(token: token, kind: .oauth, apiBaseURL: host)
            status = .success("Connected \(store.accounts.last.map { "@\($0.login)" } ?? "").")
            resetInputs()
        } catch {
            status = .failure(AuthErrorCopy.message(for: error))
        }
    }

    /// Validate + add a pasted PAT. `addAccount` calls `currentUser()`, so a bad/expired token
    /// fails here with a clear message instead of silently on the first background poll.
    private func addToken() async {
        status = .working("Validating token…")
        // Trim so a token copied with a trailing newline/spaces doesn't get rejected as invalid.
        let token = patToken.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await store.addAccount(token: token, kind: .personalAccessToken, apiBaseURL: resolvedAddURL)
            status = .success("Added \(store.accounts.last.map { "@\($0.login)" } ?? "").")
            resetInputs()
        } catch {
            status = .failure(AuthErrorCopy.message(for: error))
        }
    }

    /// Re-run whichever add-account entry the user last attempted. The PAT field is preserved
    /// until a success, so a PAT retry still has its token; the host/client-ID fields likewise
    /// persist for a device-flow retry.
    private func retry() {
        switch lastAttempt {
        case .deviceFlow: Task { await startDeviceFlow() }
        case .pat: Task { await addToken() }
        case .none: break
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
