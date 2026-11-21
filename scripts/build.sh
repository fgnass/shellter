#!/usr/bin/env bash
# Generates the Xcode project and builds Shellter.app into build/.
#   ./scripts/build.sh           Debug build
#   ./scripts/build.sh release   Release build, also writes build/Shellter.zip for a GitHub release
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:-}"
CONFIG="${CONFIG:-Debug}"
[[ "$MODE" == release ]] && CONFIG=Release

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

if [[ "$MODE" == release ]]; then
  # GhosttyKit is built for the build machine only; releases are for Apple silicon.
  [[ "$(lipo -archs "$APP/Contents/MacOS/Shellter")" == *arm64* ]] || { echo "The release must be arm64" >&2; exit 1; }
  codesign --verify --deep --strict "$APP"
  rm -f build/Shellter.zip
  ditto -c -k --keepParent "$APP" build/Shellter.zip
  echo "Wrote build/Shellter.zip" >&2
fi

echo "$ROOT/$APP"
