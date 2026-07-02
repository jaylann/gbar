# gbar development tasks
# https://just.systems — install: brew install just
#
# Run `just` (no args) to list recipes. Run `just <recipe>` to invoke one.
# gbar is a macOS menu-bar app, so build/test target `platform=macOS` (no simulator).

# Variables
project      := "gbar"
scheme       := "gbar"
derived      := justfile_directory() / "Derived"
test_results := justfile_directory() / "TestResults"

# Default: list recipes
_default:
    @just --list --unsorted

# ─── Bootstrap (one-time per clone) ─────────────────────────────────

# Wire git to use the tracked hooks in .githooks/ — run after every fresh clone
bootstrap:
    #!/usr/bin/env bash
    set -euo pipefail
    git config core.hooksPath .githooks
    echo "✓ core.hooksPath → .githooks"
    echo "  commit-msg hook now validates Conventional Commits."
    # Materialize + backfill the gitignored Tuist xcconfigs so a fresh clone can
    # `just gen`/`just build` without a "Configuration file not found / Fatal linting"
    # error. These hold PLACEHOLDER values — real per-env keys (a baked GH OAuth client
    # ID for the paid build) come from CI env.
    just _xcconfig
    echo "✓ materialized Tuist/Config/*.xcconfig from templates (fill in real keys)"

# ─── Project generation ─────────────────────────────────────────────

# Materialize the gitignored Tuist xcconfigs from their tracked templates (idempotent),
# then backfill any missing GBAR_* signing keys on pre-existing xcconfigs so Project.swift's
# $(GBAR_*) references always resolve — a missing key resolves to empty and breaks signing.
# Kept separate so `gen` is self-sufficient on a fresh clone / CI checkout.
_xcconfig:
    #!/usr/bin/env bash
    set -euo pipefail
    for cfg in Debug Release; do
        target="Tuist/Config/${cfg}.xcconfig"
        template="${target}.template"
        if [[ ! -f "$target" && -f "$template" ]]; then
            cp "$template" "$target"
        fi
        [[ -f "$target" ]] || continue
        # Ad-hoc/teamless defaults; edit these locally to sign with a real team (which
        # enables the data-protection keychain and stops the recurring keychain prompt).
        add_key() { grep -qE "^[[:space:]]*$1[[:space:]]*=" "$target" || printf '%s = %s\n' "$1" "$2" >> "$target"; }
        add_key GBAR_CODE_SIGN_STYLE Manual
        add_key GBAR_CODE_SIGN_IDENTITY -
        add_key GBAR_DEVELOPMENT_TEAM ""
        add_key GBAR_ENTITLEMENTS gbar/gbar.entitlements
        add_key GBAR_PROVISIONING_PROFILE_SPECIFIER ""
    done

# Install Tuist deps and regenerate the Xcode project
gen: _xcconfig
    tuist install
    tuist generate --no-open
    @just lsp-setup

# Regenerate buildServer.json so sourcekit-lsp (swift-lsp plugin) resolves
# cross-module symbols. The file is machine-specific (absolute DerivedData paths)
# and gitignored. No-op where xcode-build-server isn't installed (e.g. CI).
lsp-setup:
    #!/usr/bin/env bash
    set -euo pipefail
    if command -v xcode-build-server >/dev/null 2>&1; then
        xcode-build-server config -workspace {{project}}.xcworkspace -scheme {{project}}
    else
        echo "xcode-build-server not installed — skipping buildServer.json"
    fi

# Remove generated project, derived data, test results
clean:
    rm -rf "{{derived}}" {{project}}.xcodeproj {{project}}.xcworkspace "{{test_results}}"
    tuist clean 2>/dev/null || true

# Ensure the project exists before any xcodebuild call.
_ensure:
    #!/usr/bin/env bash
    set -euo pipefail
    # Self-heal a fresh clone/worktree that skipped `just bootstrap` by materializing +
    # backfilling the gitignored xcconfigs from templates before Tuist reads them.
    just _xcconfig
    if [[ ! -d "{{project}}.xcworkspace" ]]; then
        tuist install
        tuist generate --no-open
    fi
    # Format the working tree before building. Formatting happens here (and on
    # commit) — never per-Edit. swiftformat only touches files that change, so clean
    # files keep their mtime and don't trigger needless recompiles.
    if command -v swiftformat >/dev/null 2>&1; then
        swiftformat . --quiet 2>/dev/null || true
    fi

# ─── Build ──────────────────────────────────────────────────────────

# Build the macOS app (Debug)
build: _ensure
    #!/usr/bin/env bash
    set -uo pipefail
    # Serialize concurrent xcodebuild in the SAME checkout — a background build
    # colliding with a foreground build/test corrupts build.db ("database is
    # locked"). Steals the lock from a dead PID so a killed build can't wedge us.
    lock="{{derived}}/.xcodebuild.lock"; mkdir -p "{{derived}}"
    for _ in $(seq 1 600); do
        if mkdir "$lock" 2>/dev/null; then echo $$ > "$lock/pid"; break; fi
        pid=$(cat "$lock/pid" 2>/dev/null || true)
        if [[ -n "$pid" ]] && ! kill -0 "$pid" 2>/dev/null; then rm -rf "$lock"; continue; fi
        sleep 1
    done
    trap 'rm -rf "$lock" 2>/dev/null || true' EXIT
    xcodebuild \
        -workspace {{project}}.xcworkspace \
        -scheme {{scheme}} \
        -destination "platform=macOS" \
        -derivedDataPath "{{derived}}" \
        -configuration Debug \
        build | tail -30
    # Return xcodebuild's real exit code, not tail's.
    exit ${PIPESTATUS[0]}

# Build and launch the app
run: _ensure
    #!/usr/bin/env bash
    set -euo pipefail
    xcodebuild \
        -workspace {{project}}.xcworkspace \
        -scheme {{scheme}} \
        -destination "platform=macOS" \
        -derivedDataPath "{{derived}}" \
        -configuration Debug \
        build | tail -20
    app=$(find "{{derived}}/Build/Products/Debug" -maxdepth 1 -name '{{project}}.app' | head -1)
    if [[ -n "$app" ]]; then open "$app"; else echo "build product not found"; exit 1; fi

# Build, then launch the app and assert it survives startup (crash-on-launch guard)
smoke: build
    ./scripts/smoke-test.sh

# ─── Test ───────────────────────────────────────────────────────────

# Full unit test suite (macOS)
test: _ensure
    #!/usr/bin/env bash
    set -uo pipefail
    mkdir -p "{{test_results}}"
    rm -rf "{{test_results}}/latest.xcresult"
    lock="{{derived}}/.xcodebuild.lock"; mkdir -p "{{derived}}"
    for _ in $(seq 1 600); do
        if mkdir "$lock" 2>/dev/null; then echo $$ > "$lock/pid"; break; fi
        pid=$(cat "$lock/pid" 2>/dev/null || true)
        if [[ -n "$pid" ]] && ! kill -0 "$pid" 2>/dev/null; then rm -rf "$lock"; continue; fi
        sleep 1
    done
    trap 'rm -rf "$lock" 2>/dev/null || true' EXIT
    xcodebuild \
        -workspace {{project}}.xcworkspace \
        -scheme {{scheme}} \
        -destination "platform=macOS" \
        -derivedDataPath "{{derived}}" \
        -resultBundlePath "{{test_results}}/latest.xcresult" \
        test
    status=$?
    if [[ $status -eq 0 ]]; then echo "tests passed"; else echo "tests failed ($status)"; fi
    exit $status

# ─── Lint / format ──────────────────────────────────────────────────

lint:
    swiftlint lint --strict --no-cache

lint-fix:
    swiftlint lint --fix --no-cache

format:
    swiftformat .

format-check:
    swiftformat --lint .

# Spellcheck source + docs (crate-ci/typos); auto-discovers _typos.toml. Same tool as CI.
typos:
    #!/usr/bin/env bash
    set -euo pipefail
    if ! command -v typos >/dev/null 2>&1; then
        echo "typos not installed — run 'mise install' (pinned in .mise.toml)" >&2
        exit 1
    fi
    typos

# Run all lint/format checks (the same set CI runs)
check: format-check lint typos

# ─── Release ────────────────────────────────────────────────────────

# Build a Release .dmg into dist/ (ad-hoc signed). CI runs this on promote → main.
dmg:
    ./scripts/make-dmg.sh dist

# ─── Worktrees (parallel-work extras) ───────────────────────────────
#
# Worktrees live at `.claude/worktrees/gbar-wt-<slug>/`. Handy for running
# independent agents/branches in parallel without disturbing the main checkout.

# Create a worktree on a new branch + carry the gitignored Tuist xcconfigs into it.
wt-create slug:
    #!/usr/bin/env bash
    set -euo pipefail
    git worktree add .claude/worktrees/gbar-wt-{{slug}} -b feat/{{slug}}
    # `git worktree add` only brings tracked files, so a fresh worktree otherwise
    # dies in `tuist generate` with "Configuration file not found". Prefer the main
    # checkout's REAL xcconfigs; fall back to template-materialized PLACEHOLDER values.
    src_dir="{{justfile_directory()}}/Tuist/Config"
    dst_dir=".claude/worktrees/gbar-wt-{{slug}}/Tuist/Config"
    mkdir -p "$dst_dir"
    for cfg in Debug Release; do
        if [[ -f "$src_dir/${cfg}.xcconfig" ]]; then
            cp "$src_dir/${cfg}.xcconfig" "$dst_dir/${cfg}.xcconfig"
            echo "✓ copied real $cfg.xcconfig from main checkout into worktree"
        elif [[ -f "$dst_dir/${cfg}.xcconfig.template" ]]; then
            cp "$dst_dir/${cfg}.xcconfig.template" "$dst_dir/${cfg}.xcconfig"
            echo "✓ materialized $cfg.xcconfig from template (PLACEHOLDER values)"
        fi
    done
    echo "✓ worktree ready at .claude/worktrees/gbar-wt-{{slug}}"

# Remove a worktree by slug + its branch. Idempotent.
wt-rm slug:
    -git worktree remove --force .claude/worktrees/gbar-wt-{{slug}} 2>/dev/null
    git worktree prune
    git branch -D feat/{{slug}} 2>/dev/null || true

# ─── Info ───────────────────────────────────────────────────────────

# Show project + environment info
info:
    @echo "Project:       {{project}}"
    @echo "Scheme:        {{scheme}}"
    @echo "Derived:       {{derived}}"
    @tuist version 2>/dev/null || echo "tuist:         not installed"
    @swift --version | head -1 || true
    @xcodebuild -version | head -1 || true
