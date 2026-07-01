#!/usr/bin/env bash
# Build a distributable .dmg of gbar (Release config, ad-hoc signed) with a
# drag-to-Applications layout. Uses only hdiutil — no brew/create-dmg dependency.
#
# Usage: scripts/make-dmg.sh [output-dir]   (default output dir: dist/)
# Prints the path to the created .dmg on stdout.
#
# Note: the app is ad-hoc signed and NOT notarized, so first-launch requires
# right-click → Open (or `xattr -dr com.apple.quarantine gbar.app`). Developer ID
# signing + notarization is a planned follow-up (see docs/PRODUCT.md).

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
just _xcconfig
tuist install
tuist generate --no-open

echo "==> building gbar (Release)" >&2
xcodebuild \
    -workspace gbar.xcworkspace \
    -scheme gbar \
    -configuration Release \
    -derivedDataPath "$DERIVED" \
    build

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
