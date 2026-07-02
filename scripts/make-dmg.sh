#!/usr/bin/env bash
# Build a distributable .dmg of gbar (Release config) with a drag-to-Applications
# layout. Uses only hdiutil — no brew/create-dmg dependency.
#
# Usage: scripts/make-dmg.sh [output-dir]   (default output dir: dist/)
# Prints the path to the created .dmg on stdout.
#
# Signing follows Tuist/Config/Release.xcconfig: the release workflow pre-writes a
# Developer ID Application + hardened-runtime config with a Developer ID provisioning
# profile (GBAR_PROVISIONING_PROFILE_SPECIFIER) — the profile validates the sandbox's
# application-identifier + keychain-access-groups entitlements, without which the app
# won't launch. The workflow then notarizes + staples the DMG so it opens with no
# Gatekeeper prompt. A local `just dmg` without those real values falls back to ad-hoc/
# teamless signing (non-sandboxed gbar.entitlements, login keychain) — that DMG is NOT
# notarized, so first launch needs right-click → Open (or
# `xattr -dr com.apple.quarantine gbar.app`).

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

# Brand the mounted DMG with the app's own icon instead of the default disk image. Needs
# the compiled .icns from the bundle (only present once actool compiles gbar.icon — Xcode
# 26+) and SetFile (Xcode CLT). Best-effort: fall back to a plain DMG if either is missing.
ICNS=$(find "$APP/Contents/Resources" -maxdepth 1 -name '*.icns' | head -1)
VOLICON=0
if [ -n "$ICNS" ] && command -v SetFile >/dev/null 2>&1; then
    cp "$ICNS" "$STAGING/.VolumeIcon.icns"
    VOLICON=1
else
    echo "==> no app .icns or SetFile — DMG keeps the default volume icon" >&2
fi

mkdir -p "$OUT_DIR"
DMG="$OUT_DIR/gbar-$VERSION.dmg"
rm -f "$DMG"

if [ "$VOLICON" = 1 ]; then
    # Custom volume icons need HFS+ and the volume's kHasCustomIcon flag, which can only be
    # set on a mounted read-write image — so build UDRW, flag it, then convert to UDZO.
    RW="$(mktemp -u).dmg"
    MP="$(mktemp -d)"
    hdiutil create -volname "gbar $VERSION" -srcfolder "$STAGING" \
        -fs HFS+ -format UDRW -ov "$RW" >&2
    hdiutil attach "$RW" -nobrowse -noverify -mountpoint "$MP" >&2
    SetFile -a C "$MP"
    hdiutil detach "$MP" >&2
    hdiutil convert "$RW" -format UDZO -ov -o "$DMG" >&2
    rm -f "$RW"
else
    hdiutil create -volname "gbar $VERSION" -srcfolder "$STAGING" \
        -ov -format UDZO "$DMG" >&2
fi

echo "$DMG"
