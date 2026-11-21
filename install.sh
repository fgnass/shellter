#!/bin/sh
# Installs Shellter into ~/Applications.
#   curl -fsSL https://raw.githubusercontent.com/fgnass/shellter/main/install.sh | sh
#
# A download with curl gets no quarantine flag, so macOS opens the app without
# the "unidentified developer" warning.
#
# The new app is unpacked and checked first. The installed app is replaced only
# when the check passes, and it comes back if the replacement fails.
# The shells in Shellter's tabs keep running during the update (zmx sessions);
# the new version attaches to them again.
set -eu

URL="${SHELLTER_URL:-https://github.com/fgnass/shellter/releases/latest/download/Shellter.zip}"
DEST="$HOME/Applications"
APP="$DEST/Shellter.app"
BUNDLE_ID="com.fgnass.shellter"
TMP="$(mktemp -d)"
cleanup() {
  if [ -e "$TMP/old.app" ]; then
    echo "Your previous Shellter is kept in $TMP/old.app. To restore it, replace $APP with it." >&2
  else
    rm -rf "$TMP"
  fi
}
trap cleanup EXIT

fail() { echo "Error: $*" >&2; exit 1; }

[ "$(uname -m)" = arm64 ] || fail "Shellter needs a Mac with Apple silicon."

echo "Downloading Shellter…"
curl -fsSL "$URL" -o "$TMP/Shellter.zip" || fail "The download failed."

mkdir "$TMP/new"
ditto -x -k "$TMP/Shellter.zip" "$TMP/new" || fail "The download is not a valid archive."
NEW="$TMP/new/Shellter.app"
[ -x "$NEW/Contents/MacOS/Shellter" ] || fail "The archive does not contain Shellter.app."
[ "$(defaults read "$NEW/Contents/Info" CFBundleIdentifier 2>/dev/null)" = "$BUNDLE_ID" ] \
  || fail "The archive contains an unexpected app."
lipo -archs "$NEW/Contents/MacOS/Shellter" | grep -qw arm64 || fail "The app is not built for Apple silicon."
codesign --verify --deep --strict "$NEW" 2>/dev/null || fail "The signature of the app is not valid."

# Ask a running Shellter to quit, and wait for it. Quitting only detaches the tabs.
running() { pgrep -f "$APP/Contents/MacOS/Shellter" >/dev/null; }
if running; then
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  i=0
  while running; do
    i=$((i + 1))
    [ "$i" -le 100 ] || fail "Shellter is still running. Quit it and try again."
    sleep 0.1
  done
fi

mkdir -p "$DEST"
if [ -e "$APP" ]; then
  mv "$APP" "$TMP/old.app"
fi
if ! mv "$NEW" "$APP"; then
  rm -rf "$APP"
  if [ -e "$TMP/old.app" ] && mv "$TMP/old.app" "$APP"; then
    fail "Could not install to $APP. The previous version is unchanged."
  fi
  fail "Could not install to $APP."
fi
rm -rf "$TMP/old.app"

echo "Installed to $APP"
open "$APP"
