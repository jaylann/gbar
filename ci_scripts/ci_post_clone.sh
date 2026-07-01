#!/usr/bin/env bash
# Xcode Cloud post-clone hook. Runs immediately after Xcode Cloud clones the repo,
# before any Xcode build action. We use it to:
#   1. Install Tuist (via mise) + Just (via brew)
#   2. Materialize the gitignored Tuist xcconfigs from CI env vars
#   3. Generate the Xcode project from Project.swift
#
# Tuist is distributed as a brew cask which requires sudo — Xcode Cloud runners
# have no TTY for password prompts, so brew cask installs fail. mise (Tuist's
# official install path) lives entirely in $HOME and needs no privileges.

set -euxo pipefail

cd "${CI_PRIMARY_REPOSITORY_PATH:-$(pwd)}"

brew update >/dev/null
brew install just

curl -fsSL https://mise.run | sh
export PATH="$HOME/.local/bin:$PATH"
eval "$(mise activate bash --shims)"
mise use -g tuist@latest

if [ -n "${CI_XCODE_CLOUD:-}${CI:-}" ]; then
    # Materialize per-config xcconfigs from CI-set environment variables. Define
    # these in the Xcode Cloud workflow (or your CI provider's secrets). Only the
    # paid/hosted build needs a real GH_OAUTH_CLIENT_ID; self-host builds can leave
    # it blank (the app prompts for a client ID / PAT at runtime).
    mkdir -p Tuist/Config
    # Signing defaults to ad-hoc/teamless for CI (compile-only, no notarization). A signed
    # release overrides GBAR_DEVELOPMENT_TEAM + Automatic signing via the workflow env.
    cat > Tuist/Config/Debug.xcconfig <<EOF
GH_OAUTH_CLIENT_ID = ${GH_OAUTH_CLIENT_ID_DEBUG:-}
GH_API_BASE_URL = https:/\$()/${GH_API_HOST_DEBUG:-api.github.com}
GBAR_CODE_SIGN_STYLE = ${GBAR_CODE_SIGN_STYLE_DEBUG:-Manual}
GBAR_CODE_SIGN_IDENTITY = ${GBAR_CODE_SIGN_IDENTITY_DEBUG:--}
GBAR_DEVELOPMENT_TEAM = ${GBAR_DEVELOPMENT_TEAM_DEBUG:-}
GBAR_ENTITLEMENTS = ${GBAR_ENTITLEMENTS_DEBUG:-gbar/gbar.entitlements}
EOF
    cat > Tuist/Config/Release.xcconfig <<EOF
GH_OAUTH_CLIENT_ID = ${GH_OAUTH_CLIENT_ID_RELEASE:-}
GH_API_BASE_URL = https:/\$()/${GH_API_HOST_RELEASE:-api.github.com}
GBAR_CODE_SIGN_STYLE = ${GBAR_CODE_SIGN_STYLE_RELEASE:-Manual}
GBAR_CODE_SIGN_IDENTITY = ${GBAR_CODE_SIGN_IDENTITY_RELEASE:--}
GBAR_DEVELOPMENT_TEAM = ${GBAR_DEVELOPMENT_TEAM_RELEASE:-}
EOF
else
    echo "ci_post_clone.sh: not running in CI — skipping xcconfig materialization"
fi

tuist install
tuist generate --no-open
