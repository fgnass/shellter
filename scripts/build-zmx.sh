#!/usr/bin/env bash
# Builds zmx (session persistence, https://github.com/neurosnap/zmx) from the pinned
# submodule. Shellter bundles this binary, so the client and the daemons that
# outlive the app always speak the same protocol.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ZMX="$ROOT/vendor/zmx"

if [[ ! -f "$ZMX/build.zig" ]]; then
  git -C "$ROOT" submodule update --init vendor/zmx
fi

echo "==> Building zmx"
(cd "$ZMX" && zig build -Doptimize=ReleaseSafe)

mkdir -p "$ROOT/vendor/bin"
cp "$ZMX/zig-out/bin/zmx" "$ROOT/vendor/bin/zmx"
echo "==> Done: vendor/bin/zmx"
