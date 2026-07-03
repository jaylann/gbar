import Foundation

/// The device-flow half of adding an account, moved out of `AccountsPane` so the view keeps
/// only UI state (status line, code card) and the orchestration is store-owned and testable —
/// mirrors `AppStore+Reauth`, which runs the same dance to replace an expired token in place.
extension AppStore {
    /// Run the full device flow for a **new** account against `apiBaseURL`'s web host:
    /// request a device code, surface it via `onUserCode` (the pane renders it as a copyable
    /// card), open the verification page via the injected `openURL`, poll until the user
    /// authorizes, then register the account through `addAccount(token:kind:apiBaseURL:)`.
    /// Failures are thrown for the caller to translate (`AuthErrorCopy`).
    func addAccountViaDeviceFlow(
        clientID: String,
        apiBaseURL: URL,
        openURL: (URL) -> Void,
        onUserCode: (String) -> Void
    ) async throws {
        let client = makeDeviceFlowClient(clientID, AppConfig.webBaseURL(forAPI: apiBaseURL))
        let code = try await client.requestDeviceCode(scopes: DeviceFlowClient.defaultScopes)
        onUserCode(code.userCode)
        // `verificationUri` is host-returned (semi-trusted on Enterprise) — gate it through the
        // same http(s) allowlist as every other host URL before opening it.
        if let url = WebLink.parse(code.verificationUri) { openURL(url) }
        let token = try await client.pollForToken(code)
        try await addAccount(token: token, kind: .oauth, apiBaseURL: apiBaseURL)
    }
}
