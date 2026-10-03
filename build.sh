#!/bin/bash
# Builds MacroClicker.app (release) and optionally installs it to /Applications.
#   ./build.sh            -> build ./MacroClicker.app
#   ./build.sh install    -> build and copy to /Applications
#   UNIVERSAL=1 ./build.sh -> one app for both Apple silicon and Intel Macs (used for releases)
set -euo pipefail
cd "$(dirname "$0")"

VERSION="$(cat VERSION)"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
ARCHS=()
if [[ "${UNIVERSAL:-}" == "1" ]]; then ARCHS=(--arch arm64 --arch x86_64); fi
swift build -c release ${ARCHS[@]+"${ARCHS[@]}"}
BIN="$(swift build -c release ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)/MacroClicker"

APP="MacroClicker.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MacroClicker"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>MacroClicker</string>
    <key>CFBundleDisplayName</key><string>MacroClicker</string>
    <key>CFBundleIdentifier</key><string>local.macroclicker.app</string>
    <key>CFBundleExecutable</key><string>MacroClicker</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
</dict>
</plist>
PLIST

# Sign with the personal certificate from scripts/setup-signing.sh when available. Its signature stays the
# same across rebuilds, so Accessibility / Input Monitoring permissions don't have to be granted again.
# Falls back to ad-hoc signing (permissions then reset on every rebuild).
IDENTITY="MacroClicker Local Signing"
if security find-identity -p codesigning | grep -q "\"$IDENTITY\""; then
    codesign --force --deep --sign "$IDENTITY" --identifier local.macroclicker.app "$APP"
else
    echo "warning: \"$IDENTITY\" not found; ad-hoc signing. Run scripts/setup-signing.sh to keep permissions across rebuilds."
    codesign --force --deep --sign - --identifier local.macroclicker.app "$APP"
fi
echo "Built $(pwd)/$APP"

if [[ "${1:-}" == "install" ]]; then
    pkill -x MacroClicker 2>/dev/null || true
    rm -rf "/Applications/$APP"
    cp -R "$APP" /Applications/
    echo "Installed to /Applications/$APP"
fi
