import Foundation

/// The background poll loop for `AppStore`. Extracted so the main type stays within SwiftLint's
/// `file_length`; the loop only touches non-`private(set)` state (`pollTask`, `pollInterval`,
/// `rateLimitedUntil`) so it lives cleanly in its own file.
extension AppStore {
    /// Start (or restart) the background poll loop. Cancels any existing loop first; a no-op
    /// when signed out or when polling is `.off`.
    func startPolling() {
        pollTask?.cancel()
        guard isSignedIn, pollInterval > 0 else {
            pollTask = nil
            return
        }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.isSignedIn, self.pollInterval > 0 else { return }
                // `refresh()` is single-flight, so a menu-triggered or manual refresh already in
                // flight coalesces here rather than racing this poll tick. See #10.
                await self.refresh()
                // Honour a rate-limit reset: sleep to whichever is longer, the configured cadence
                // or the reported reset time, so we don't re-poll straight into GitHub's limit.
                let backoff = self.rateLimitedUntil.map { max(0, $0.timeIntervalSinceNow) } ?? 0
                let seconds = max(self.pollInterval, backoff)
                do {
                    try await Task.sleep(for: .seconds(seconds))
                } catch {
                    return // cancelled
                }
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }
}
