#!/usr/bin/env bash
# Launch smoke test: run the built app and assert it survives startup.
#
# Catches the class of regression unit tests can't see — crash-on-launch, broken
# entitlements/signing, dyld/link failures — without any flaky UI driving. The app is
# an LSUIElement MenuBarExtra agent, so "alive after N seconds" is the right liveness
# signal; there's no window to assert on.
#
# Usage: scripts/smoke-test.sh [path/to/gbar.app]  (default: Derived Debug product)
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
app="${1:-$root/Derived/Build/Products/Debug/gbar.app}"
binary="$app/Contents/MacOS/gbar"
grace_seconds=10

if [[ ! -x "$binary" ]]; then
    echo "::error::app binary not found at $binary — run 'just build' first" >&2
    exit 1
fi

log="$(mktemp -t gbar-smoke)"
"$binary" > "$log" 2>&1 &
pid=$!
trap 'kill "$pid" 2>/dev/null || true' EXIT

for i in $(seq 1 "$grace_seconds"); do
    sleep 1
    if ! kill -0 "$pid" 2>/dev/null; then
        wait "$pid" || status=$?
        echo "::error::gbar exited after ${i}s with status ${status:-0}" >&2
        echo "--- app output ---" >&2
        cat "$log" >&2
        exit 1
    fi
done

kill "$pid" 2>/dev/null || true
echo "✓ smoke test passed — app alive after ${grace_seconds}s"
