#!/usr/bin/env bash
set -euo pipefail

# Fast local check that mirrors the CI gate (report-only there, blocking here):
# build the app and run the full Swift Testing suite.
# Ad-hoc signing embeds entitlements without needing a developer account.
echo "Building and testing Antimatter..."
xcodebuild test \
  -project antimatter.xcodeproj \
  -scheme antimatter \
  -destination 'platform=macOS' \
  -derivedDataPath build \
  CODE_SIGN_IDENTITY="-"