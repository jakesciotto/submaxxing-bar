#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(sed -n 's/.*static let version = "\(.*\)"/\1/p' Sources/SubmaxxingBar/AppInfo.swift)

UNIVERSAL=1 ./scripts/build-app.sh
mkdir -p dist
ditto -c -k --keepParent "build/Submaxxing Bar.app" dist/SubmaxxingBar.zip

if [[ "${1:-}" == "publish" ]]; then
  gh release create "v$VERSION" dist/SubmaxxingBar.zip --target main --title "v$VERSION" --generate-notes
else
  echo "packaged: $PWD/dist/SubmaxxingBar.zip (run with 'publish' to create v$VERSION)"
fi
