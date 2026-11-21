#!/usr/bin/env bash
# Builds GhosttyKit.xcframework from the pinned Ghostty submodule and copies
# the runtime resources (shell integration, terminfo) into Resources/.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GHOSTTY="$ROOT/vendor/ghostty"
OPTIMIZE="${OPTIMIZE:-ReleaseFast}"

if [[ ! -f "$GHOSTTY/build.zig" ]]; then
  git -C "$ROOT" submodule update --init vendor/ghostty
fi

echo "==> Building GhosttyKit.xcframework ($OPTIMIZE)"
(
  cd "$GHOSTTY"
  zig build \
    -Demit-xcframework=true \
    -Demit-macos-app=false \
    -Dxcframework-target=native \
    -Doptimize="$OPTIMIZE"
)

echo "==> Copying xcframework and resources"
rm -rf "$ROOT/vendor/GhosttyKit.xcframework"
cp -R "$GHOSTTY/macos/GhosttyKit.xcframework" "$ROOT/vendor/GhosttyKit.xcframework"

mkdir -p "$ROOT/Resources"
rm -rf "$ROOT/Resources/ghostty" "$ROOT/Resources/terminfo"
cp -R "$GHOSTTY/zig-out/share/ghostty" "$ROOT/Resources/ghostty"
cp -R "$GHOSTTY/zig-out/share/terminfo" "$ROOT/Resources/terminfo"

echo "==> Done"
