import AppKit
import SwiftUI

/// The Accounts settings pane: the connected GitHub identities up top (each removable on
/// hover), then an add-account form that toggles between the two supported credential kinds —
/// device flow and a pasted personal access token. The technical knobs (OAuth client ID,
/// Enterprise host) live behind a single "Advanced" disclosure; the client ID defaults to the
/// baked/stored one, so the common path is one primary button. Sign-out-all lives at the
/// bottom. All the auth wiring (typed status, error copy) is preserved from the previous form.
struct AccountsPane: View {
    @Bindable var store: AppStore
    @Environment(\.openURL) private var openURL

    /// The user's explicit client-ID override; blank means "use the baked/stored default".
    @State private var clientID = ""
    @State private var patToken = ""
    /// Optional per-account host override for the account being added (blank = default host).
    @State private var addHost = ""
    /// The chosen add-account credential kind, so only the relevant fields show.
    @State private var method: Method = .deviceFlow
    /// Client ID + Enterprise host are off the common path — revealed on demand.
    @State private var showsAdvanced = false
    /// The live device-flow user code, surfaced as its own copyable card while we poll.
    @State private var deviceCode: String?
    /// Typed sign-in state, rendered as a loading / error / success line under the controls.
    @State private var status: AuthStatus = .idle
    /// Which entry last ran, so the failure state's "Try again" re-runs the right one.
    @State private var lastAttempt: Method?

    private enum Method: Hashable {
        case deviceFlow
        case pat
    }

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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                connectedSection
                addAccountSection
                if store.isSignedIn {
                    signOutSection
                }
            }
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, Theme.Spacing.md)
        }
        .onAppear {
            // Self-host with no usable client ID anywhere: open Advanced so the required field
            // is visible instead of leaving a mysteriously disabled sign-in button.
            if effectiveClientID.isEmpty { showsAdvanced = true }
        }
        // Don't retain a pasted token in memory after the window closes without a successful add.
        .onDisappear { patToken = "" }
    }

    // MARK: Connected accounts

    @ViewBuilder
    private var connectedSection: some View {
        if store.accounts.isEmpty {
            EmptyStateView(
                intent: .neutral,
                title: "No accounts yet",
                message: "Add a GitHub account below to start tracking your PRs, issues, and inbox."
            )
        } else {
            VStack(alignment: .leading, spacing: 0) {
                SectionHeader(title: "Connected", count: store.accounts.count)
                ForEach(store.accounts) { account in
                    accountRow(account)
                }
            }
        }
    }

    private func accountRow(_ account: Account) -> some View {
        HoverRow(trailingAccessory: {
            Button(role: .destructive) {
                store.removeAccount(id: account.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(GBButtonStyle(variant: .icon))
            .gbTooltip("Remove \(account.login)")
            .accessibilityLabel("Remove \(account.login)")
        }, content: {
            HStack(spacing: Theme.Spacing.sm) {
                Avatar(login: account.login, url: account.avatarImageURL, size: .medium)
                VStack(alignment: .leading, spacing: 1) {
                    Text(account.login)
                        .font(Theme.Typography.rowTitle)
                    Text(hostLabel(account.apiBaseURL))
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.secondary)
                }
            }
        })
    }

    // MARK: Add account

    private var addAccountSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            SectionHeader(title: "Add account")
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                methodChips
                switch method {
                case .deviceFlow: deviceFlowFields
                case .pat: patFields
                }
                advancedDisclosure
                statusView
            }
            .padding(.horizontal, Theme.Spacing.md)
        }
    }

    private var methodChips: some View {
        HStack(spacing: Theme.Spacing.xs) {
            FilterChip(title: "Sign in with GitHub", symbol: "person.badge.key", isOn: methodBinding(.deviceFlow))
            FilterChip(title: "Access token", symbol: "key", isOn: methodBinding(.pat))
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var deviceFlowFields: some View {
        if let deviceCode {
            deviceCodeCard(deviceCode)
        }
        Button {
            lastAttempt = .deviceFlow
            Task { await startDeviceFlow() }
        } label: {
            Text("Sign in with GitHub")
        }
        .buttonStyle(GBButtonStyle(variant: .primary, isLoading: status.isWorking && lastAttempt == .deviceFlow))
        .disabled(effectiveClientID.isEmpty || status.isWorking || hostFieldError != nil)
        Text("Opens github.com in your browser to authorize gbar.")
            .font(Theme.Typography.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var patFields: some View {
        SecureField("Personal access token", text: $patToken)
            .modifier(SettingsFieldStyle())
        Button {
            lastAttempt = .pat
            Task { await addToken() }
        } label: {
            Text("Add token")
        }
        .buttonStyle(GBButtonStyle(variant: .primary, isLoading: status.isWorking && lastAttempt == .pat))
        .disabled(patToken.isEmpty || status.isWorking || hostFieldError != nil)
    }

    /// The device-flow user code as its own card: large, spaced monospace with a copy button,
    /// so it's legible at a glance and easy to paste into the browser prompt.
    private func deviceCodeCard(_ code: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text("Enter this code in the browser")
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: Theme.Spacing.sm) {
                Text(code)
                    .font(Theme.Typography.deviceCode)
                    .tracking(3)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(GBButtonStyle(variant: .icon))
                .gbTooltip("Copy code")
                .accessibilityLabel("Copy device code")
            }
        }
        .padding(Theme.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Surface.controlFill, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
    }

    /// The technical knobs — OAuth client ID (device flow only) and Enterprise host — behind one
    /// disclosure, so the common github.com case is just a button.
    @ViewBuilder
    private var advancedDisclosure: some View {
        DisclosureLink(title: "Advanced", isExpanded: $showsAdvanced)
        if showsAdvanced {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                if method == .deviceFlow {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        TextField(
                            "OAuth App client ID",
                            text: $clientID,
                            prompt: Text(defaultClientID.isEmpty ? "OAuth App client ID" : defaultClientID)
                        )
                        .modifier(SettingsFieldStyle())
                        if defaultClientID.isEmpty {
                            ValidationHint(message: "Self-hosted builds need a GitHub OAuth App client ID to sign in.")
                        } else {
                            Text("Leave blank to use the built-in client ID.")
                                .font(Theme.Typography.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    TextField("API base URL", text: $addHost, prompt: Text(store.apiBaseURL.absoluteString))
                        .modifier(SettingsFieldStyle())
                    if let hostFieldError {
                        ValidationHint(message: hostFieldError)
                    } else {
                        Text("Leave blank for github.com. For GitHub Enterprise, e.g. https://ghe.example.com/api/v3")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
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
            HStack(spacing: Theme.Spacing.xs) {
                ProgressView().controlSize(.small)
                Text(message)
            }
            .font(Theme.Typography.caption)
            .foregroundStyle(.secondary)
        case let .failure(message):
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.closed)
                Button("Try again") { retry() }
                    .buttonStyle(GBButtonStyle(variant: .secondary))
                    .disabled(status.isWorking)
            }
        case let .success(message):
            Label(message, systemImage: "checkmark.circle.fill")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.open)
        }
    }

    // MARK: Sign out

    private var signOutSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
                .padding(.vertical, Theme.Spacing.xs)
            Button("Sign out of all accounts", role: .destructive) { store.signOutAll() }
                .buttonStyle(GBButtonStyle(variant: .ghost))
        }
        .padding(.horizontal, Theme.Spacing.md)
    }

    // MARK: Selection helpers

    /// Drives the two method chips as radio buttons — turning one on selects it; you can't turn
    /// the active one off (a method must always be chosen).
    private func methodBinding(_ value: Method) -> Binding<Bool> {
        Binding(
            get: { method == value },
            set: { isOn in
                guard isOn else { return }
                // Don't leave a typed token sitting in view memory after switching to device flow.
                if value != .pat { patToken = "" }
                method = value
            }
        )
    }

    // MARK: Auth

    /// The client ID used when the user hasn't typed an override: baked into the build if
    /// present, else the last one persisted on the store (self-host remembers it).
    private var defaultClientID: String {
        AppConfig.bakedClientID ?? store.oauthClientID
    }

    /// The client ID a sign-in actually uses: the typed override when non-blank, else the default.
    private var effectiveClientID: String {
        let typed = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.isEmpty ? defaultClientID : typed
    }

    /// The host a newly-added account should use: the override field if filled and valid, else the
    /// app default. `hostFieldError` gates submission, so an invalid override never reaches here.
    private var resolvedAddURL: URL {
        HostField.url(addHost) ?? store.apiBaseURL
    }

    /// An inline error when the Advanced host field isn't a usable https base URL (see `HostField`).
    private var hostFieldError: String? {
        HostField.error(addHost)
    }

    private func resetInputs() {
        patToken = ""
        addHost = ""
        deviceCode = nil
    }

    private func startDeviceFlow() async {
        status = .working("Requesting a device code…")
        deviceCode = nil
        do {
            try await store.addAccountViaDeviceFlow(
                clientID: effectiveClientID,
                apiBaseURL: resolvedAddURL,
                openURL: { openURL($0) },
                onUserCode: { code in
                    deviceCode = code
                    status = .working("Waiting for you to authorize in the browser…")
                }
            )
            // Persist the (public) client ID only on success, so a typo'd override that failed to
            // sign in doesn't get baked into the store and fed to a future 401 reconnect. Only a
            // typed override is written — the baked default shouldn't overwrite a stored self-host value.
            if !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                store.oauthClientID = effectiveClientID
            }
            status = .success("Connected \(store.accounts.last.map { "@\($0.login)" } ?? "").")
            resetInputs()
        } catch {
            deviceCode = nil
            status = .failure(AuthErrorCopy.message(for: error))
            Log.auth.error("device-flow sign-in failed: \(error, privacy: .public)")
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

    /// Re-run whichever add-account entry the user last attempted. Input fields persist until a
    /// success, so a retry still has its token / client ID.
    private func retry() {
        switch lastAttempt {
        case .deviceFlow: Task { await startDeviceFlow() }
        case .pat: Task { await addToken() }
        case .none: break
        }
    }
}

/// Short, human-readable host for an account's API base URL.
private func hostLabel(_ url: URL) -> String {
    guard let host = url.host else { return url.absoluteString }
    return host == "api.github.com" ? "github.com" : host
}

/// Validation for the optional Enterprise host override. `URL(string:)` is lenient enough that a
/// scheme-less `ghe.corp.com` parses as a relative path (no host), which would make every request
/// malformed and surface only as a vague later failure; and `http://` would leak the bearer token
/// in cleartext. A blank field is valid (use the default host). `internal` (not `private`) so it's
/// unit-testable — this is the same cleartext-guard as `WebLink`.
enum HostField {
    /// The validated override URL, or nil when blank/invalid.
    static func url(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed),
              url.scheme?.lowercased() == "https", url.host != nil
        else { return nil }
        return url
    }

    /// An inline error message when the field is non-blank but not a usable https base URL.
    static func error(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return url(trimmed) == nil
            ? "Enter a full https URL including the host, e.g. https://ghe.example.com/api/v3"
            : nil
    }
}

#if DEBUG
#Preview("AccountsPane") {
    AccountsPane(store: AppStore())
        .frame(width: Theme.Layout.settingsWidth, height: Theme.Layout.settingsHeight)
        .background(Surface.canvas)
}
#endif
