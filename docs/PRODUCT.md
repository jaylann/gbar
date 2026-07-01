# gbar — product definition

**gbar** is a macOS menu-bar window that aggregates everything you care about on GitHub
into one glanceable place. It's inspired by [PullBar](https://github.com/menubar-apps/PullBar)
but aims broader — a *general* GitHub bar, not a PR-only viewer.

## Principles

1. **Glanceable.** The most important state (PRs needing your review, failing CI, new
   review requests) is visible from the menu bar icon/badge without opening anything.
2. **Source-available, self-hostable, no paid clones.** Anyone can run, self-host and
   modify gbar for free. The [PolyForm Shield](../LICENSE) license forbids using it to
   build a competing product — so the paid tier that funds the project stays viable.
3. **Bring-your-own auth, or pay for convenience.** Free users register their own GitHub
   OAuth App (device flow, no backend). Paid users get a pre-configured build.

## Feature scope

### v1 (MVP)
- **Pull requests:** created / assigned / review-requested / mentioned. Per PR: title,
  number, repo, author, approval count, +/- line counts, age.
- **Issues:** created / assigned / mentioned.
- **Checks / CI:** per-check-run status (success / failure / pending) on each PR.
- **Quick actions:** open in browser, approve, merge, mark notification read.
- **Desktop notifications:** new PRs, review requests assigned to you, status changes.
- **Multiple accounts / orgs** and **GitHub Enterprise** (custom API base URL).
- **Custom saved queries:** arbitrary GitHub search strings become menu sections.
- Configurable poll interval; menu-bar badge with counts.

### Backlog (post-v1)
Keeps the "general GitHub bar" promise:
- Full **notifications inbox** (the `/notifications` feed).
- **Releases**, **GitHub Actions** workflow-run status, starred/watched repos,
  discussions, gists.
- **Real-time** updates via a hosted webhook backend (the paid convenience tier), instead
  of polling.

## Authentication

- **Device flow** is primary: needs only a **public client ID** — no client secret, no
  callback server. Ideal for a desktop app.
- **Free / self-host:** user supplies their own OAuth App client ID (see
  [`SELF-HOST.md`](SELF-HOST.md)).
- **Paid / hosted:** build ships with the licensor's client ID pre-baked.
- **Fallback:** classic personal access token (PAT) for zero-OAuth setups.
- Tokens live in the **macOS Keychain**.

## Configuration surface

Injected at build time via `Tuist/Config/{Debug,Release}.xcconfig` → Info.plist:
- `GH_OAUTH_CLIENT_ID` — blank for self-host builds (prompt at runtime), pre-filled for paid.
- `GH_API_BASE_URL` — defaults to `https://api.github.com`; overridden for Enterprise.

## Distribution (deferred)

v1 ships as a self-built / ad-hoc-signed binary. Developer ID signing + notarization,
a Homebrew cask, and GitHub Releases artifacts come in a follow-up once the app is
feature-complete enough to ship.
