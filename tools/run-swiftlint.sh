#!/usr/bin/env bash
set -euo pipefail

# Run SwiftLint if installed. For "recommended" setup this only warns locally
# instead of failing the build. CI can opt into strict mode.
if command -v swiftlint >/dev/null 2>&1; then
  echo "Running SwiftLint..."
  # Run lint; don't treat warnings as errors here (recommended mode)
  swiftlint lint || true
else
  cat <<'MSG'
swiftlint is not installed. To enable linting:
  • Install via Homebrew: brew install swiftlint
  • Or add SwiftLint as an Xcode Package: File → Add Packages… → https://github.com/realm/SwiftLint

Once installed, re-run this script or add it as a Run Script Phase in the Xcode scheme.
MSG
fi
