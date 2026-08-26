#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP="build/PRBar.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp Info.plist "$APP/Contents/"
[ -f AppIcon.icns ] && cp AppIcon.icns "$APP/Contents/Resources/"
[ -f menubar-mark.png ] && cp menubar-mark.png "$APP/Contents/Resources/"

swiftc -parse-as-library -O -o "$APP/Contents/MacOS/PRBar" \
    PRCore.swift \
    App.swift \
    -framework SwiftUI -framework AppKit \
    -target arm64-apple-macos13.0

chmod 755 "$APP/Contents/MacOS/PRBar"
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "Built: $APP"
open "$APP"
