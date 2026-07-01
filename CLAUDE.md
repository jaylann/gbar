# gbar — project memory

macOS menu-bar GitHub companion (PRs, issues, CI, notifications, quick actions). Broader
than PullBar; a *general* GitHub bar. See `docs/PRODUCT.md` for scope.

## Non-obvious constraints

- **License is PolyForm Shield 1.0.0 (source-available, NOT OSI open source).** The
  no-compete clause is deliberate — it protects the paid/hosted tier. Don't describe the
  project as "open source"; say "source-available". Keep the `Required Notice:` and
  `Licensor Line of Business:` lines in `LICENSE` intact.
- **Auth = GitHub OAuth device flow + PAT fallback, no backend in v1.** Device flow needs
  only a public client ID. Self-host builds ship a blank `GH_OAUTH_CLIENT_ID`; the paid
  build bakes one in via `Tuist/Config/Release.xcconfig`. Tokens go in the Keychain.
- **macOS app, not iOS.** `MenuBarExtra` + `LSUIElement` agent (no dock icon). Tuist target
  `destinations: [.mac]`, macOS 14, bundle id `dev.lanfermann.gbar`. `just build`/`test` use
  `platform=macOS` (no simulator).
- **Signing:** ad-hoc (`CODE_SIGN_IDENTITY = -`) so a fresh clone builds without a Developer
  team. Notarization/Developer ID is deferred backlog.

## Conventions

Standard Justin Swift/Tuist repo: `just` for all tasks, SwiftFormat+SwiftLint (`just check`),
Conventional Commits, `stage` working branch / `main` release-only. CI lints only; tests run
locally. Global setup: `~/.claude/memory/` (profile + projects catalog).
