# Security Policy

## Supported versions

Only the latest release of gbar receives security fixes. If you're on an older build,
update first — the fix will land in a new release, not be backported.

| Version | Supported |
| ------- | --------- |
| latest release | ✅ |
| anything older | ❌ |

## Reporting a vulnerability

**Please do not open a public issue for security problems.**

Report privately via GitHub's private vulnerability reporting:
[github.com/jaylann/gbar/security/advisories/new](https://github.com/jaylann/gbar/security/advisories/new).
If that doesn't work for you, email [justin@lanfermann.dev](mailto:justin@lanfermann.dev).

Include what you can: affected version, macOS version, reproduction steps, and impact
(e.g. token exposure, keychain access, network interception).

You'll get an acknowledgement within **72 hours** and a status update within **7 days**.
Once a fix ships, the advisory is published and you'll be credited (unless you'd rather
not be).

## Scope notes

- gbar stores GitHub credentials **only in the macOS Keychain** — anything that causes a
  token to touch disk in plaintext is a vulnerability, report it.
- Auth uses GitHub's OAuth **device flow** (public client ID, no secret) or a PAT. There
  is no gbar server in v1; the app talks directly to the GitHub API you configure.
