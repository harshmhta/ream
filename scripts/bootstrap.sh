#!/usr/bin/env bash
# Bootstrap the Ream Xcode project from project.yml.
#
# The .xcodeproj is a generated artifact (git-ignored) so parallel contributors
# never fight over its internal state. Run this after cloning or after changing
# project.yml, then open Ream.xcodeproj in Xcode.
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "==> XcodeGen not found. Installing via Homebrew…"
  if command -v brew >/dev/null 2>&1; then
    brew install xcodegen
  else
    echo "error: Homebrew not found. Install XcodeGen: https://github.com/yonaskolb/XcodeGen" >&2
    exit 1
  fi
fi

echo "==> Generating Ream.xcodeproj from project.yml"
xcodegen generate
echo "==> Done. Open Ream.xcodeproj in Xcode (15+) on macOS 14+."
