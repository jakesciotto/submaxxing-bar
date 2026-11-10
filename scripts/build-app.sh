#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

NAME="Submaxxing Bar"
EXECUTABLE="SubmaxxingBar"
VERSION=$(sed -n 's/.*static let version = "\(.*\)"/\1/p' Sources/SubmaxxingBar/AppInfo.swift)

ARCH_FLAGS=()
if [[ "${UNIVERSAL:-0}" == "1" ]]; then ARCH_FLAGS=(--arch arm64 --arch x86_64); fi
swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BINARY="$(swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)/$EXECUTABLE"

APP="build/$NAME.app"
mkdir -p "$APP/Contents/MacOS"
cp "$BINARY" "$APP/Contents/MacOS/$EXECUTABLE"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>io.github.jakesciotto.submaxxing-bar</string>
  <key>CFBundleExecutable</key><string>$EXECUTABLE</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP"

if [[ "${1:-}" == "install" ]]; then
  pkill -x "$EXECUTABLE" 2>/dev/null || true
  mkdir -p "$HOME/Applications"
  ditto "$APP" "$HOME/Applications/$NAME.app"
  open "$HOME/Applications/$NAME.app"
  echo "installed: $HOME/Applications/$NAME.app"
else
  echo "built: $PWD/$APP"
fi
