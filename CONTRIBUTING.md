# Contributing to gbar

Thanks for your interest! gbar is source-available under the
[PolyForm Shield License 1.0.0](LICENSE).

## Contribution terms

By submitting a contribution (PR, patch, etc.) you agree that your contribution is
licensed to the project under the **same PolyForm Shield 1.0.0** terms as the rest of
the code, and that you have the right to license it. No separate CLA to sign — this
note is the agreement.

## Setup

```bash
just bootstrap   # install git hooks + materialize local xcconfigs
just gen         # generate the Xcode project
just check       # SwiftFormat + SwiftLint
just test        # run the test suite
```

## Branch & PR flow

- Branch off **`stage`**; open PRs against `stage`. `main` is release-only.
- Name branches `<type>/<slug>` matching the commit type, e.g. `feat/inbox-filters`,
  `fix/menu-flicker`.
- Feature/fix PRs into `stage` are **squash-merged**, so the **PR title must be a
  Conventional Commit** (`type(scope): subject`, lowercase subject). The `stage` → `main`
  promotion PR is the exception — it's **merge-committed**, never squashed (see Releases).

## Commit conventions

[Conventional Commits](https://www.conventionalcommits.org/). Types: `feat fix chore
docs refactor test perf style ci build revert`. Breaking changes use `!`
(e.g. `feat(api)!:`).

## Code standards

- Keep functions small and typed; add tests for behavior changes.
- Use `os.Logger` (not `print`), no force-`try`, reference issues in TODOs (`TODO(#123)`).
- Run `just check` before pushing — CI runs the same set, **plus** `just build` and
  `just test`, so run those too before opening a PR.

## Releases

Run the **cut release** action (Actions tab → pick a bump) — it bumps `Project.swift`,
creates the milestone, opens the `stage` → `main` promotion PR, and enables auto-merge on
it. Once the required checks pass the PR **merge-commits** into `main` (never squash, so
`main` keeps `stage`'s history) and that's the release: `release.yml` tags `vX.Y.Z`, builds
the signed + notarized DMG, uploads it to the GitHub release, updates the Homebrew cask, and
back-merges `main` into `stage`. If you ever merge a promotion PR by hand, pick **Create a
merge commit** — squashing it re-diverges the branches.
