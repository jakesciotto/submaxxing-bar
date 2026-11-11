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
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/$EXECUTABLE"

ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$ICONSET")"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>io.github.jakesciotto.submaxxing-bar</string>
  <key>CFBundleExecutable</key><string>$EXECUTABLE</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
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
  DEST="/Applications"
  [[ -w "$DEST" ]] || DEST="$HOME/Applications"
  mkdir -p "$DEST"
  rm -rf "${DEST:?}/$NAME.app"
  ditto "$APP" "$DEST/$NAME.app"
  if [[ "$DEST" == "/Applications" ]]; then rm -rf "$HOME/Applications/$NAME.app"; fi
  open "$DEST/$NAME.app"
  echo "installed: $DEST/$NAME.app"
else
  echo "built: $PWD/$APP"
fi
