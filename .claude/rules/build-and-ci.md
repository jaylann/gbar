# Build & CI

- `just` is the entry point for everything: `just gen`, `just build`, `just test`,
  `just check`, `just dmg`. It's a **macOS** app — build/test target `platform=macOS`
  (no simulator).
- Formatting runs via `just` (and on commit), never per-edit. Don't add a per-Edit format hook.
- Signing is ad-hoc (`CODE_SIGN_IDENTITY = -`) so a fresh clone builds without a team.
- CI (`ci.yml`): lint + compile-build + typos. Release (`release.yml`): promote `stage` →
  `main` → tag + build DMG + upload to the GitHub release. Bump `marketingVersion` in
  `Project.swift` to cut a release.
- Branches: work on `stage`; `main` is release/tag-only.
