#!/usr/bin/env bash
# Xcode Cloud pre-xcodebuild hook. Logs build context. Add bump logic here if needed.

set -euo pipefail

echo "=== gbar Xcode Cloud build ==="
echo "Workflow:  ${CI_WORKFLOW:-unknown}"
echo "Action:    ${CI_XCODEBUILD_ACTION:-unknown}"
echo "Build:     ${CI_BUILD_NUMBER:-unknown}"
echo "Tag:       ${CI_TAG:-none}"
echo "Branch:    ${CI_BRANCH:-none}"
echo "Commit:    ${CI_COMMIT:-unknown}"
echo "================================"
