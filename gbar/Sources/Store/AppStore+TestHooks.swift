import Foundation

#if DEBUG
/// Test-only accessors into `AppStore`'s internal state. Extracted from the main file (which is at
/// its SwiftLint `file_length` budget) — these reach only `internal` members, so they compose
/// cleanly from a sibling file.
extension AppStore {
    /// Test hook: await the current CI hydration wave (if any) to completion.
    func awaitChecksHydration() async {
        await checksTask?.value
    }

    /// Test hook: hand back the in-flight hydration task so a test can hold a reference across
    /// a sign-out (which nils the store's own reference) and still await the wave.
    var checksHydrationTaskForTests: Task<Void, Never>? {
        checksTask
    }

    /// Test hook: seed/inspect the pending legacy token so migration can be driven in a test.
    var pendingLegacyTokenForTests: String? {
        get { pendingLegacyToken }
        set { pendingLegacyToken = newValue }
    }
}
#endif
