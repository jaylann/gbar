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
- PRs are **squash-merged**, so the **PR title must be a Conventional Commit**
  (`type(scope): subject`, lowercase subject).

## Commit conventions

[Conventional Commits](https://www.conventionalcommits.org/). Types: `feat fix chore
docs refactor test perf style ci build revert`. Breaking changes use `!`
(e.g. `feat(api)!:`).

## Code standards

- Keep functions small and typed; add tests for behavior changes.
- Use `os.Logger` (not `print`), no force-`try`, reference issues in TODOs (`TODO(#123)`).
- Run `just check` before pushing — CI runs the same set.

## Releases

Merge `stage` → `main` via a promotion PR; `release.yml` reads `marketingVersion` from
`Project.swift`, tags `vX.Y.Z`, and cuts the GitHub release.
