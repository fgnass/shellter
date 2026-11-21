#!/usr/bin/env bash
# Generates the Xcode project and builds Shellter.app into build/.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${CONFIG:-Debug}"

if [[ ! -d "$ROOT/vendor/GhosttyKit.xcframework" ]]; then
  "$ROOT/scripts/build-ghostty.sh"
fi

if [[ ! -x "$ROOT/vendor/bin/zmx" ]]; then
  "$ROOT/scripts/build-zmx.sh"
fi

if [[ ! -d "$ROOT/Resources/Fonts" ]]; then
  "$ROOT/scripts/fetch-fonts.sh"
fi

# Sign with an "Apple Development" certificate when there is one. Then macOS knows
# each new build as the same app and keeps its privacy permissions. An ad-hoc
# signature changes with every build, so macOS asks for the permissions again.
SIGN_ARGS=()
CERT="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development: .*\)"/\1/p' | head -1)"
if [[ -n "$CERT" ]]; then
  TEAM="$(security find-certificate -c "$CERT" -p | openssl x509 -noout -subject | sed -n 's/.*OU=\([A-Z0-9]*\).*/\1/p')"
  SIGN_ARGS=(CODE_SIGN_IDENTITY="$CERT" DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_STYLE=Manual)
fi

cd "$ROOT"
xcodegen generate --quiet
xcodebuild \
  -project Shellter.xcodeproj \
  -scheme Shellter \
  -configuration "$CONFIG" \
  -derivedDataPath build/DerivedData \
  -quiet \
  build ${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"}

APP="build/DerivedData/Build/Products/$CONFIG/Shellter.app"
echo "$ROOT/$APP"
