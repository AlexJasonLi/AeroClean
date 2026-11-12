#!/bin/bash
# builds build/MacCleaner.app. pass --install to copy it into /Applications.
# SIGN_IDENTITY picks a code-signing identity; the default is ad-hoc ("-").
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product MacCleaner
bin="$(swift build -c release --show-bin-path)/MacCleaner"
app="build/MacCleaner.app"

if [ ! -f build/AppIcon.icns ] || [ scripts/make-icon.swift -nt build/AppIcon.icns ]; then
    swift scripts/make-icon.swift build/AppIcon.icns
fi

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/MacCleaner"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp build/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
codesign --force --sign "${SIGN_IDENTITY:--}" "$app"
echo "built $app"

if [ "${1:-}" = "--install" ]; then
    rm -rf /Applications/MacCleaner.app
    ditto "$app" /Applications/MacCleaner.app
    echo "installed /Applications/MacCleaner.app"
fi
