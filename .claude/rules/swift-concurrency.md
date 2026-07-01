# Swift 6 concurrency

- Strict concurrency is **on** (`SWIFT_STRICT_CONCURRENCY = complete`). Everything must be
  `Sendable`-clean.
- UI + app state (`AppStore`, SwiftUI views) live on `@MainActor`. Networking lives in
  `actor`s / `nonisolated async` calls (`DeviceFlowClient`, `GitHubClient`).
- Models are value types with only `Sendable` members, so they get **implicit** `Sendable` —
  do **not** re-add explicit `: Sendable` to internal structs/enums (SwiftFormat's
  `redundantSendable` strips it).
- No `print` (use `Log.<category>`), no force-`try`, no force-unwrap. TODOs must cite an
  issue: `TODO(#123)` — otherwise prefer a plain `Note:` comment.
