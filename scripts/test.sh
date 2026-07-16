#!/usr/bin/env bash
# Build and test Ream headlessly — mirrors what CI runs.
set -euo pipefail

cd "$(dirname "$0")/.."

./scripts/bootstrap.sh

echo "==> Building and testing Ream"
xcodebuild \
  -scheme Ream \
  -destination "platform=macOS" \
  -resultBundlePath "build/ReamTests.xcresult" \
  clean build test
