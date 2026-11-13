#!/bin/bash
# builds build/AeroClean.app. pass --install to copy it into /Applications.
# SIGN_IDENTITY picks a code-signing identity; the default is ad-hoc ("-").
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product AeroClean
swift build -c release --product Snapshots
bins="$(swift build -c release --show-bin-path)"
bin="$bins/AeroClean"
app="build/AeroClean.app"

mkdir -p build
"$bins/Snapshots" icon build/AppIcon.icns

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/AeroClean"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp build/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cp Resources/Fonts/DepartureMono-Regular.otf Resources/Fonts/DepartureMono-LICENSE.txt "$app/Contents/Resources/"
codesign --force --sign "${SIGN_IDENTITY:--}" "$app"
echo "built $app"

if [ "${1:-}" = "--install" ]; then
    rm -rf /Applications/AeroClean.app
    ditto "$app" /Applications/AeroClean.app
    echo "installed /Applications/AeroClean.app"
fi
