#!/usr/bin/env bash
# Build a distributable .dmg of gbar (Release config) with a drag-to-Applications
# layout. Uses only hdiutil — no brew/create-dmg dependency.
#
# Usage: scripts/make-dmg.sh [output-dir]   (default output dir: dist/)
# Prints the path to the created .dmg on stdout.
#
# Signing follows Tuist/Config/Release.xcconfig: the release workflow pre-writes a
# Developer ID Application + hardened-runtime config (then notarizes + staples the DMG),
# so the shipped build opens with no Gatekeeper prompt. A local `just dmg` without those
# real values falls back to ad-hoc/teamless signing — that DMG is NOT notarized, so
# first launch needs right-click → Open (or `xattr -dr com.apple.quarantine gbar.app`).

set -euo pipefail

cd "$(dirname "$0")/.."

VERSION=$(grep -oE 'marketingVersion = "[^"]+"' Project.swift | head -1 | sed 's/.*"\(.*\)"/\1/')
[ -n "$VERSION" ] || { echo "could not read marketingVersion from Project.swift" >&2; exit 1; }

OUT_DIR="${1:-dist}"
DERIVED="build"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

echo "==> generating project" >&2
# Materialize + backfill the gitignored xcconfigs before Tuist reads them, so a fresh CI
# checkout has them and existing ones gain any new keys (notably GBAR_ENTITLEMENTS — an
# undefined value makes CODE_SIGN_ENTITLEMENTS empty and ships an app with no entitlements).
# stdout is the script's contract (the DMG path on the last line), so every tool's chatter
# goes to stderr — otherwise tuist's "✔ Success" et al. pollute the captured path.
just _xcconfig >&2
tuist install >&2
tuist generate --no-open >&2

echo "==> building gbar (Release)" >&2
xcodebuild \
    -workspace gbar.xcworkspace \
    -scheme gbar \
    -configuration Release \
    -derivedDataPath "$DERIVED" \
    build >&2

APP=$(find "$DERIVED/Build/Products/Release" -maxdepth 1 -name 'gbar.app' | head -1)
[ -n "$APP" ] || { echo "gbar.app not found under $DERIVED/Build/Products/Release" >&2; exit 1; }

echo "==> packaging DMG" >&2
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

mkdir -p "$OUT_DIR"
DMG="$OUT_DIR/gbar-$VERSION.dmg"
rm -f "$DMG"
hdiutil create \
    -volname "gbar $VERSION" \
    -srcfolder "$STAGING" \
    -ov -format UDZO \
    "$DMG" >&2

echo "$DMG"
