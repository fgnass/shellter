#!/usr/bin/env bash
# Generates the Xcode project and builds Shellter.app into build/.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${CONFIG:-Debug}"

if [[ ! -d "$ROOT/vendor/GhosttyKit.xcframework" ]]; then
  "$ROOT/scripts/build-ghostty.sh"
fi

if [[ ! -d "$ROOT/Resources/Fonts" ]]; then
  "$ROOT/scripts/fetch-fonts.sh"
fi

cd "$ROOT"
xcodegen generate --quiet
xcodebuild \
  -project Shellter.xcodeproj \
  -scheme Shellter \
  -configuration "$CONFIG" \
  -derivedDataPath build/DerivedData \
  -quiet \
  build

APP="build/DerivedData/Build/Products/$CONFIG/Shellter.app"
echo "$ROOT/$APP"
