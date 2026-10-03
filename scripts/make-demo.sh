#!/bin/bash
# Builds a separate "demo" copy of MacroClicker with neutral example data, for README screenshots.
# It uses its own data folder and settings (bundle id local.macroclicker.demo), so real macros are untouched.
#   scripts/make-demo.sh                build demo data + demo app, then launch it
#   scripts/make-demo.sh --screenshots  same, but take the README screenshots automatically and quit
#   scripts/make-demo.sh --build-only   just build the demo data and app (used by scripts/qa-sweep.sh)
set -euo pipefail
cd "$(dirname "$0")/.."
DEMO="${DEMO_DIR:-$PWD/.demo}"
SRC=Sources/MacroClicker
mkdir -p "$DEMO/gen"
cp scripts/demo-data.swift "$DEMO/gen/main.swift"
swiftc -O -o "$DEMO/gen/demo-data" $SRC/Models.swift $SRC/KeyNames.swift $SRC/Target.swift $SRC/EventSynth.swift \
    $SRC/Watchers.swift $SRC/Hotkeys.swift $SRC/ScreenReader.swift $SRC/Storage.swift $SRC/FrameSource.swift $SRC/Lookup.swift "$DEMO/gen/main.swift"
"$DEMO/gen/demo-data" "$DEMO/home"

./build.sh >/dev/null
rm -rf "$DEMO/MacroClicker.app"
cp -R MacroClicker.app "$DEMO/MacroClicker.app"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier local.macroclicker.demo" "$DEMO/MacroClicker.app/Contents/Info.plist"
codesign --force --deep --sign - --identifier local.macroclicker.demo "$DEMO/MacroClicker.app" 2>/dev/null
if [[ "${1:-}" == "--build-only" ]]; then
    exit 0
elif [[ "${1:-}" == "--screenshots" ]]; then
    # Steps through the pages, saves docs/screenshots/*.png and quits by itself.
    MACROCLICKER_HOME="$DEMO/home" MACROCLICKER_SCREENSHOTS=1 MACROCLICKER_SCREENSHOT_DIR="${SHOTS_DIR:-$PWD/docs/screenshots}" \
        "$DEMO/MacroClicker.app/Contents/MacOS/MacroClicker" >/dev/null 2>&1
    ls -1 docs/screenshots
else
    MACROCLICKER_HOME="$DEMO/home" MACROCLICKER_SCREENSHOTS=1 "$DEMO/MacroClicker.app/Contents/MacOS/MacroClicker" >/dev/null 2>&1 &
    echo "Demo running (pid $!) with data in $DEMO/home"
fi
