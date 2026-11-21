#!/usr/bin/env bash
# Builds Shellter, quits the running instance of this build and starts the new one.
# The tabs come back with their directories; processes in them stop.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$("$ROOT/scripts/build.sh" | tail -1)"
BIN="$APP/Contents/MacOS/Shellter"

if pgrep -f "^$BIN" >/dev/null; then
  pkill -TERM -f "^$BIN" || true
  for _ in $(seq 1 50); do
    pgrep -f "^$BIN" >/dev/null || break
    sleep 0.1
  done
  pkill -KILL -f "^$BIN" || true
fi

# `open` sometimes fails with error -600 right after the old instance quit, mostly when
# it runs in a Shellter tab. Try again until the new instance runs.
for _ in $(seq 1 5); do
  open "$APP" 2>/dev/null || true
  for _ in $(seq 1 20); do
    pgrep -f "^$BIN" >/dev/null && { echo "$APP"; exit 0; }
    sleep 0.2
  done
done
echo "error: Shellter did not start" >&2
exit 1
