#!/bin/bash
# Records the README demo GIF (docs/demo.gif): Heron claims rewards in a small practice app as they light up.
# Uses the installed Heron (it has the permissions) with the demo data, so your own macros never appear.
# Heron is quit first and reopened normally at the end.
#   scripts/record-demo.sh [seconds]
set -euo pipefail
cd "$(dirname "$0")/.."
SECONDS_TO_RECORD="${1:-16}"
DEMO="$PWD/.demo"
APP=/Applications/Heron.app
HERON_ID=local.macroclicker.app

# Demo data (neutral example macros) in .demo/home.
scripts/make-demo.sh --build-only >/dev/null

# The practice app.
R="$DEMO/Rewards.app/Contents"
mkdir -p "$R/MacOS"
swiftc -O -o "$R/MacOS/Rewards" scripts/demo-target.swift 2>/dev/null
cat > "$R/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.example.rewards</string>
<key>CFBundleName</key><string>Rewards</string>
<key>CFBundleExecutable</key><string>Rewards</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
PLIST
codesign --force --sign - "$DEMO/Rewards.app" 2>/dev/null

# The recorder.
mkdir -p "$DEMO/gen"
swiftc -O -o "$DEMO/gen/record-demo" scripts/record-demo.swift 2>/dev/null

osascript -e 'with timeout of 15 seconds' -e "tell application id \"$HERON_ID\" to quit" -e 'end timeout' 2>/dev/null || true
pkill -x Rewards 2>/dev/null || true
sleep 1

open --env DEMO_WINDOW_ORIGIN=1000,220 "$DEMO/Rewards.app"
open --env HERON_HOME="$DEMO/home" --env HERON_DEMO_PLAY="Claim rewards" --env HERON_DEMO_DELAY=1.5 "$APP"
sleep 2.5
"$DEMO/gen/record-demo" docs/demo.gif "$SECONDS_TO_RECORD" "$HERON_ID" com.example.rewards

osascript -e 'with timeout of 15 seconds' -e "tell application id \"$HERON_ID\" to quit" -e 'end timeout' 2>/dev/null || true
pkill -x Rewards 2>/dev/null || true
sleep 1
open "$APP"
