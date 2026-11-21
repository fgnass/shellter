#!/usr/bin/env bash
# Runs the logic tests (ShellterTests). They do not start the app, and they build into
# their own folder, so they never replace the signed app in build/DerivedData.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
xcodegen generate --quiet
LOG="$(mktemp)"
status=0
xcodebuild test \
  -project Shellter.xcodeproj \
  -scheme Shellter \
  -only-testing:ShellterTests \
  -derivedDataPath build/TestData >"$LOG" 2>&1 || status=$?
grep -E "error:|' failed|Executed [0-9]+ tests?, .* in .*\) seconds$|\*\* TEST" "$LOG" | sort -u || true
rm -f "$LOG"
exit $status
