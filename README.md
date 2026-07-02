<h1 align="center">gbar</h1>

<p align="center">
  A general <strong>GitHub companion in your macOS menu bar</strong> — pull requests,
  issues, CI status, notifications and quick actions, always one glance away.
</p>

<p align="center">
  <em>Like <a href="https://github.com/menubar-apps/PullBar">PullBar</a>, but broader —
  and source-available.</em>
</p>

<p align="center">
  <a href="https://github.com/jaylann/gbar/actions/workflows/ci.yml"><img src="https://github.com/jaylann/gbar/actions/workflows/ci.yml/badge.svg?branch=stage" alt="CI"></a>
  <a href="https://github.com/jaylann/gbar/releases/latest"><img src="https://img.shields.io/github/v/release/jaylann/gbar" alt="Latest release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-PolyForm%20Shield%201.0.0-blue" alt="License: PolyForm Shield 1.0.0"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-black" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Swift-6-orange" alt="Swift 6">
</p>

---

## What it does

gbar lives in your menu bar and pulls together everything you care about on GitHub:

- **Pull requests** — created / assigned / review-requested / mentioned, with author,
  approvals, +/- line counts and age.
- **Issues** — created / assigned / mentioned.
- **Rich CI / checks** — per-check pass/fail/pending status on your PRs.
- **Quick actions** — open in browser, approve, merge, mark notifications read.
- **Desktop notifications** — new PRs, review requests, status changes.
- **Multiple accounts, orgs & GitHub Enterprise** — point it at any API base URL.
- **Custom saved queries** — any GitHub search string becomes its own menu section.

See [`docs/PRODUCT.md`](docs/PRODUCT.md) for the full scope and roadmap.

## Free & self-hosted vs. paid convenience

gbar is **free to run, self-host and modify**. Authentication uses GitHub's OAuth
**device flow**, which needs only a public client ID — no server, no secret.

- **Self-host (free):** register your own GitHub OAuth App in ~2 minutes, paste its
  client ID into Settings once (or use a personal access token). Guide:
  [`docs/SELF-HOST.md`](docs/SELF-HOST.md).
- **Paid ("I'll configure it for you"):** get a build pre-configured with a ready-to-go
  client ID (and, later, a hosted convenience backend) so you just click
  *Sign in with GitHub*. This funds maintenance. Contact
  [lanfermann.dev](https://lanfermann.dev).

Your tokens are stored in the **macOS Keychain**, never on disk in plaintext.

## Stack

SwiftUI (`MenuBarExtra`, `LSUIElement` agent) · macOS 14+ · Swift 6 (strict
concurrency) · [Tuist](https://tuist.dev) · SwiftFormat + SwiftLint · `just`.

## Setup

```bash
just bootstrap   # wire git hooks + materialize local xcconfigs
just gen         # tuist install + generate the Xcode project
just build       # build the macOS app
just run         # build and launch
```

## Conventions

- **Branches:** `stage` is the working branch; `main` is release/tag-only.
- **Commits:** [Conventional Commits](https://www.conventionalcommits.org/) — enforced
  by a local `commit-msg` hook and the `pr-title` CI check.
- **Lint/format:** `just check` (SwiftFormat + SwiftLint). Run before pushing.

## License

**Source-available under the [PolyForm Shield License 1.0.0](LICENSE).** You may use,
self-host, modify and redistribute gbar freely — but **not** to build a product or
service that competes with gbar or with the paid/hosted gbar offering. This is *not*
an OSI-approved "open source" license; that's deliberate, so the paid tier that funds
the project can't simply be resold out from under it.
