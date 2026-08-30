#!/usr/bin/env bash
# Build and test Ream headlessly — mirrors what CI runs.
set -euo pipefail

cd "$(dirname "$0")/.."

./scripts/bootstrap.sh

# The app scheme only carries the ReamTests bundle, so `xcodebuild test` does not
# run ReamCore's package tests. Run them explicitly — same as CI does.
echo "==> Testing ReamCore package"
swift test --package-path ReamCore

echo "==> Building and testing Ream"
xcodebuild \
  -scheme Ream \
  -destination "platform=macOS" \
  -resultBundlePath "build/ReamTests.xcresult" \
  clean build test
