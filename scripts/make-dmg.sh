#!/usr/bin/env bash
# Build a distributable .dmg of gbar (Release config) with a drag-to-Applications
# layout. Uses only hdiutil — no brew/create-dmg dependency.
#
# Usage: scripts/make-dmg.sh [output-dir]   (default output dir: dist/)
# Prints the path to the created .dmg on stdout.
#
# GBAR_APP=<path to a built gbar.app> skips project generation + the Release build —
# handy when iterating on DMG packaging/layout only.
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

if [ -n "${GBAR_APP:-}" ]; then
    APP="$GBAR_APP"
    [ -d "$APP" ] || { echo "GBAR_APP does not exist: $APP" >&2; exit 1; }
    echo "==> reusing prebuilt app: $APP" >&2
else

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

fi # GBAR_APP

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

# Custom install screen: pack the committed 1x/2x backgrounds into a retina TIFF
# (tiffutil ships with macOS). The Finder layout itself (.DS_Store) is written below
# while the RW image is mounted. Best-effort: a missing asset just means a plain DMG.
BG=0
if [ -f assets/dmg/background.png ] && [ -f assets/dmg/background@2x.png ] \
    && command -v tiffutil >/dev/null 2>&1; then
    mkdir -p "$STAGING/.background"
    tiffutil -cathidpicheck assets/dmg/background.png assets/dmg/background@2x.png \
        -out "$STAGING/.background/background.tiff" >&2
    BG=1
else
    echo "==> no DMG background assets or tiffutil — plain Finder window" >&2
fi

mkdir -p "$OUT_DIR"
DMG="$OUT_DIR/gbar-$VERSION.dmg"
rm -f "$DMG"

if [ "$VOLICON" = 1 ] || [ "$BG" = 1 ]; then
    # Volume icon + Finder layout both need HFS+ and a mounted read-write image (the
    # kHasCustomIcon flag and the volume .DS_Store can only be set live) — so build
    # UDRW, mutate the mounted volume, then convert to UDZO.
    RW="$(mktemp -u).dmg"
    hdiutil create -volname "gbar $VERSION" -srcfolder "$STAGING" \
        -fs HFS+ -format UDRW -ov "$RW" >&2
    # Attach browsable (no -nobrowse): Finder must see the disk to script its window.
    # Parse the real mount point from hdiutil in case /Volumes/<name> is taken.
    MP=$(hdiutil attach "$RW" -noverify | grep -oE '/Volumes/.+$' | head -1)
    [ -n "$MP" ] || { echo "could not mount RW image" >&2; exit 1; }
    VOLNAME=$(basename "$MP")
    [ "$VOLICON" = 1 ] && SetFile -a C "$MP"
    if [ "$BG" = 1 ]; then
        # Write the Finder window layout (background, bounds, icon positions) into the
        # volume's .DS_Store. Best-effort: on a headless/Finder-less runner this fails
        # without failing the release — the DMG then opens with default Finder layout.
        if osascript >&2 <<EOF
tell application "Finder"
    tell disk "$VOLNAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 860, 548}
        set viewOpts to the icon view options of container window
        set arrangement of viewOpts to not arranged
        set icon size of viewOpts to 128
        set text size of viewOpts to 12
        set label position of viewOpts to bottom
        set background picture of viewOpts to file ".background:background.tiff"
        set position of item "gbar.app" of container window to {166, 205}
        set position of item "Applications" of container window to {494, 205}
        -- close + reopen, then re-assert the window state: Finder only reliably
        -- persists bounds/toolbar/statusbar into .DS_Store from the last close.
        close
        open
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 860, 548}
        update without registering applications
        delay 2
        close
        delay 1
    end tell
end tell
EOF
        then
            # Give Finder time to flush .DS_Store before the volume detaches.
            sync
            sleep 2
        else
            echo "==> Finder layout failed (headless?) — DMG keeps default layout" >&2
        fi
    fi
    # Finder may still hold the volume briefly after the layout script — retry forced.
    hdiutil detach "$MP" >&2 || { sleep 2; hdiutil detach "$MP" -force >&2; }
    hdiutil convert "$RW" -format UDZO -ov -o "$DMG" >&2
    rm -f "$RW"
else
    hdiutil create -volname "gbar $VERSION" -srcfolder "$STAGING" \
        -ov -format UDZO "$DMG" >&2
fi

# Brand the .dmg FILE's own Finder icon (distinct from the mounted-volume icon set
# above). Custom file icons live in the resource fork: embed the icns into itself,
# extract it as an 'icns' resource, append it to the DMG, then flag the file as having
# a custom icon. Needs DeRez/Rez (Xcode CLT).
#
# Two deliberate limits: (1) resource forks travel as xattrs and are stripped by HTTP
# downloads, so a DMG fetched from a GitHub release still shows the generic icon — only
# local/AirDrop copies keep it. (2) The release DMG is Developer ID-signed, notarized,
# and stapled downstream; branding buys nothing there (stripped on download) and would
# ride the fork into codesign/stapler, so skip signed builds entirely. Everything here
# is cosmetic — keep it strictly best-effort so a failure never aborts the build (which
# would also swallow the stdout DMG-path contract that release.yml captures).
# Match with a bash glob (not grep) so this doesn't depend on grep's flavor.
SIGN_INFO=$(codesign -dvv "$APP" 2>&1 || true)
if [[ "$SIGN_INFO" == *"Authority=Developer ID Application"* ]]; then
    echo "==> signed release build — skipping .dmg file-icon (stripped on download)" >&2
elif [ -n "$ICNS" ] && command -v Rez >/dev/null 2>&1 && command -v DeRez >/dev/null 2>&1; then
    if {
        cp "$ICNS" "$STAGING/icon.icns" &&
        sips -i "$STAGING/icon.icns" >&2 &&
        DeRez -only icns "$STAGING/icon.icns" > "$STAGING/icon.rsrc" &&
        Rez -append "$STAGING/icon.rsrc" -o "$DMG" &&
        SetFile -a C "$DMG"
    }; then :; else
        echo "==> .dmg file-icon branding failed — keeping default icon" >&2
    fi
else
    echo "==> no app .icns or Rez/DeRez — .dmg file keeps the default icon" >&2
fi

echo "$DMG"
