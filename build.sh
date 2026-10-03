#!/bin/bash
# Builds Heron.app (release) and optionally installs it to /Applications.
#   ./build.sh            -> build ./Heron.app
#   ./build.sh install    -> build and copy to /Applications
#   UNIVERSAL=1 ./build.sh -> one app for both Apple silicon and Intel Macs (used for releases)
set -euo pipefail
cd "$(dirname "$0")"

VERSION="$(cat VERSION)"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
ARCHS=()
if [[ "${UNIVERSAL:-}" == "1" ]]; then ARCHS=(--arch arm64 --arch x86_64); fi
swift build -c release ${ARCHS[@]+"${ARCHS[@]}"}
BIN="$(swift build -c release ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)/Heron"

APP="Heron.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Heron"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/MenuBarIcon.png Resources/MenuBarIcon@2x.png "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Heron</string>
    <key>CFBundleDisplayName</key><string>Heron</string>
    <key>CFBundleIdentifier</key><string>local.macroclicker.app</string><!-- kept from the old name: permissions and settings stay -->
    <key>CFBundleExecutable</key><string>Heron</string>
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
# The certificate keeps its original name (from when the app was called MacroClicker): renaming it would
# make macOS forget the permissions already granted.
IDENTITY="MacroClicker Local Signing"
if security find-identity -p codesigning | grep -q "\"$IDENTITY\""; then
    codesign --force --deep --sign "$IDENTITY" --identifier local.macroclicker.app "$APP"
else
    echo "warning: \"$IDENTITY\" not found; ad-hoc signing. Run scripts/setup-signing.sh to keep permissions across rebuilds."
    codesign --force --deep --sign - --identifier local.macroclicker.app "$APP"
fi
echo "Built $(pwd)/$APP"

if [[ "${1:-}" == "install" ]]; then
    pkill -x Heron 2>/dev/null || true
    pkill -x MacroClicker 2>/dev/null || true
    rm -rf "/Applications/$APP"
    rm -rf "/Applications/MacroClicker.app" # the app's previous name
    cp -R "$APP" /Applications/
    echo "Installed to /Applications/$APP"
fi
