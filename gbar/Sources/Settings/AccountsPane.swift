import AppKit
import SwiftUI

/// The Accounts settings pane: the connected GitHub identities up top (each removable on
/// hover), then an add-account form that toggles between the two supported credential kinds —
/// device flow (public OAuth client ID) and a pasted personal access token — with the optional
/// Enterprise host tucked behind a disclosure. Sign-out-all lives at the bottom. All the
/// auth wiring (typed status, in-place client-ID persistence, error copy) is preserved from
/// the previous form; only the presentation moves onto the design system.
struct AccountsPane: View {
    @Bindable var store: AppStore
    @Environment(\.openURL) private var openURL

    @State private var clientID = AppConfig.bakedClientID ?? ""
    @State private var patToken = ""
    /// Optional per-account host override for the account being added (blank = default host).
    @State private var addHost = ""
    /// The chosen add-account credential kind, so only the relevant fields show.
    @State private var method: Method = .deviceFlow
    /// The Enterprise host field is off the common path — revealed on demand.
    @State private var showsHostField = false
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
            // Seed the field from the persisted (public) client ID so a returning user doesn't
            // retype it; the baked build already has it, self-host remembers the last one used.
            if clientID.isEmpty { clientID = store.oauthClientID }
        }
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
                hostDisclosure
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
        TextField("OAuth App client ID", text: $clientID)
            .modifier(SettingsFieldStyle())
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
        .disabled(clientID.isEmpty || status.isWorking)
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
        .disabled(patToken.isEmpty || status.isWorking)
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
                    .font(.system(size: 22, weight: .semibold, design: .monospaced))
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

    /// Enterprise host, revealed on demand so the common github.com case stays uncluttered.
    @ViewBuilder
    private var hostDisclosure: some View {
        Button {
            withAnimation(Motion.spring) { showsHostField.toggle() }
        } label: {
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(showsHostField ? 90 : 0))
                Text("Enterprise host")
            }
            .font(Theme.Typography.caption)
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        if showsHostField {
            TextField("API base URL", text: $addHost, prompt: Text(store.apiBaseURL.absoluteString))
                .modifier(SettingsFieldStyle())
            Text("Leave blank for github.com. For GitHub Enterprise, e.g. https://ghe.example.com/api/v3")
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)
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
            set: { isOn in if isOn { method = value } }
        )
    }

    // MARK: Auth

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
        deviceCode = nil
    }

    private func startDeviceFlow() async {
        status = .working("Requesting a device code…")
        deviceCode = nil
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
            deviceCode = code.userCode
            status = .working("Waiting for you to authorize in the browser…")
            if let url = URL(string: code.verificationURI) { openURL(url) }
            let token = try await client.pollForToken(code)
            try await store.addAccount(token: token, kind: .oauth, apiBaseURL: host)
            status = .success("Connected \(store.accounts.last.map { "@\($0.login)" } ?? "").")
            resetInputs()
        } catch {
            deviceCode = nil
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

/// A plain field restyled to sit on the design system: quiet fill, small radius, matching the
/// height of `GBButtonStyle`. Scoped to Settings' text inputs; not a global component.
private struct SettingsFieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(Theme.Typography.caption)
            .padding(.horizontal, Theme.Spacing.sm)
            .frame(height: 28)
            .background(Surface.controlFill, in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
    }
}

#if DEBUG
#Preview("AccountsPane") {
    AccountsPane(store: AppStore())
        .frame(width: 500, height: 560)
        .background(Surface.canvas)
}
#endif
