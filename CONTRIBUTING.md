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
- PRs are **squash-merged**, so the **PR title must be a Conventional Commit**
  (`type(scope): subject`, lowercase subject).

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
creates the milestone, and opens the `stage` → `main` promotion PR. Merging that PR is the
release: `release.yml` tags `vX.Y.Z`, builds the signed + notarized DMG, uploads it to the
GitHub release, and updates the Homebrew cask.
