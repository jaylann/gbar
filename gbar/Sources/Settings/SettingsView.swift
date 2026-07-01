import SwiftUI

/// Settings: connect an account (device flow or PAT) and point gbar at a GitHub host.
/// Deliberately minimal for the scaffold — the deeper preferences (saved queries, poll
/// interval, notifications) attach here as the app grows. See docs/PRODUCT.md.
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
            advancedSection
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 420)
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
        let client = DeviceFlowClient(clientID: clientID)
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
