#!/usr/bin/env bash
set -euo pipefail

REPO="jakesciotto/submaxxing-bar"
NAME="Submaxxing Bar"
EXECUTABLE="SubmaxxingBar"
DEST="$HOME/Applications"

fail() { echo "submaxxing bar: $*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || fail "macOS only."
major=$(sw_vers -productVersion | cut -d. -f1)
(( major >= 14 )) || fail "needs macOS 14 or later."

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo "downloading the latest release..."
if curl -fsSL -o "$tmp/app.zip" "https://github.com/$REPO/releases/latest/download/$EXECUTABLE.zip"; then
  ditto -x -k "$tmp/app.zip" "$tmp/out"
else
  echo "no release found, building from source..."
  xcode-select -p >/dev/null 2>&1 || {
    xcode-select --install 2>/dev/null || true
    fail "install the Xcode command line tools from the dialog, then run this again."
  }
  git clone --quiet --depth 1 "https://github.com/$REPO.git" "$tmp/src"
  "$tmp/src/scripts/build-app.sh" >/dev/null
  mkdir -p "$tmp/out"
  ditto "$tmp/src/build/$NAME.app" "$tmp/out/$NAME.app"
fi

[[ -d "$tmp/out/$NAME.app" ]] || fail "the download did not contain $NAME.app."

pkill -x "$EXECUTABLE" 2>/dev/null || true
mkdir -p "$DEST"
rm -rf "${DEST:?}/$NAME.app"
ditto "$tmp/out/$NAME.app" "$DEST/$NAME.app"
xattr -dr com.apple.quarantine "$DEST/$NAME.app" 2>/dev/null || true
open "$DEST/$NAME.app"

echo "installed $DEST/$NAME.app and opened it."
echo "look for the meter in your menu bar. if it is hidden, check Bartender or System Settings > Menu Bar."
