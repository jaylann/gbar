import Foundation

/// Per-account 401 recovery: `expiredAccount`, `canReconnect`, and the in-place
/// `reconnect(openURL:)`. Kept in an extension so `AppStore`'s main body stays within
/// SwiftLint's `type_body_length`; the stateful setters (`reauthStatus`, `expiredAccountID`)
/// live on the main type.
extension AppStore {
    /// The account whose session expired, if any — resolved from `expiredAccountID` against the
    /// live account list (a since-removed account resolves to `nil`).
    var expiredAccount: Account? {
        guard let id = expiredAccountID else { return nil }
        return accounts.first { $0.id == id }
    }

    /// Whether the expired session can be recovered *in place* via the device flow: only when
    /// that account was signed in with OAuth and we still know its client ID. A PAT account (or a
    /// self-host build with no stored client ID) can't reconnect this way and must re-add the
    /// account in Settings.
    var canReconnect: Bool {
        expiredAccount?.kind == .oauth && !oauthClientID.isEmpty
    }

    /// Re-run the device flow to replace an expired **OAuth** account's token *in place*,
    /// preserving its identity: the fresh token is written back into the same Keychain slot
    /// (keyed by the account's `login`), so its metadata, filters, and notification baselines all
    /// carry over. Opens the verification URL via the injected `openURL` (kept in the view layer
    /// so the store stays UI-framework-light) and publishes progress through `reauthStatus` so
    /// the 401 prompt can render the user code and outcome.
    ///
    /// No-op when `canReconnect` is false (PAT account, or no stored client ID) — the caller
    /// should route those to Settings instead. Device-flow tokens have no refresh token, so this
    /// is a genuine re-auth, not a silent refresh (see `ReauthStatus`).
    func reconnect(openURL: (URL) -> Void) async {
        guard canReconnect, let account = expiredAccount else { return }
        // Reentrancy guard: a rapid double-tap can enqueue two reconnect Tasks before the view
        // re-renders and hides the button. Bail if one is already in flight so we don't start two
        // racing device-flow sessions.
        switch reauthStatus {
        case .awaitingAuthorization,
             .starting:
            return
        case .failed,
             .idle:
            break
        }
        reauthStatus = .starting
        // Fresh local actor for the async calls (Sendable) — its host is this account's own
        // web host, so an Enterprise account reconnects against its own instance.
        let client = DeviceFlowClient(
            clientID: oauthClientID,
            webBaseURL: AppConfig.webBaseURL(forAPI: account.apiBaseURL)
        )
        do {
            let code = try await client.requestDeviceCode(scopes: DeviceFlowClient.defaultScopes)
            reauthStatus = .awaitingAuthorization(code: code.userCode)
            if let url = URL(string: code.verificationUri) { openURL(url) }
            let token = try await client.pollForToken(code)
            // Same Keychain slot => the account's identity is preserved; the device flow itself
            // proves the token works, so no separate validation round-trip is needed.
            try storeToken(token, account.keychainKey)
            reauthStatus = .idle
            // Force a fresh refresh so the error/expired state is recomputed from the just-stored
            // token — coalescing onto an in-flight poll run (built from the old, expired token)
            // would leave the account marked expired and the Reconnect prompt showing. #10.
            await refresh(force: true)
        } catch {
            reauthStatus = .failed(AuthErrorCopy.message(for: error))
            Log.auth.error("reconnect failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
