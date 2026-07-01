# GitHub integration

- All PR/issue data goes through the `GitHubAPI` protocol (`GitHubClient` is the live REST
  impl over `/search/issues`, header `X-GitHub-Api-Version: 2022-11-28`). Add new surfaces to
  that protocol so the store stays testable and a future hosted backend can swap in.
- Auth is **device flow** (`DeviceFlowClient`) — public client ID only, no secret, no server —
  or a PAT fallback. Never introduce a client secret or a callback server into the app.
- Credentials live in the **Keychain** (`KeychainStore`), never in `UserDefaults`/plaintext.
- The API base URL is configurable (`AppStore.apiBaseURL`) for GitHub Enterprise — don't
  hardcode `api.github.com` in call sites.
