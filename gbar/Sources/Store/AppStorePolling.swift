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
                do {
                    try await Task.sleep(for: .seconds(self.nextPollDelay()))
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

    /// Delay before the next poll tick: the configured cadence, or a longer wait when GitHub asked
    /// us to back off past it (`rateLimitedUntil`), so we don't re-poll straight into the limit.
    func nextPollDelay(now: Date = Date()) -> TimeInterval {
        Self.pollDelay(pollInterval: pollInterval, rateLimitedUntil: rateLimitedUntil, now: now)
    }

    /// Pure delay computation (injectable inputs) so the backoff logic is unit-testable without
    /// driving the real `Task.sleep` loop.
    static func pollDelay(pollInterval: TimeInterval, rateLimitedUntil: Date?, now: Date) -> TimeInterval {
        let backoff = rateLimitedUntil.map { max(0, $0.timeIntervalSince(now)) } ?? 0
        return max(pollInterval, backoff)
    }
}
