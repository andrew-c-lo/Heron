#!/bin/bash
# QA: cropper logic + real mouse/scroll events into the real cropper view (off-screen window), and click spread.
# Any build or test failure stops the run with a non-zero exit.
set -euo pipefail
cd "$(dirname "$0")/../../Sources/MacroClicker"
OUT="$(mktemp -d)"
run() { # name, test file, sources...
    local name="$1" test="$2"; shift 2
    mkdir -p "$OUT/$name"
    cp "../../Tests/qa/$test" "$OUT/$name/main.swift"
    echo "== $name"
    swiftc -O -o "$OUT/$name/t" "$@" "$OUT/$name/main.swift"
    "$OUT/$name/t" "$OUT/$name.png" 2>/dev/null | tee "$OUT/$name.log"
    grep -q "ALL PASSED" "$OUT/$name.log"
}
run cropper-logic cropper-logic.swift Views/RegionPicker.swift
run cropper-events cropper-events.swift Views/RegionPicker.swift
run click-spread click-spread.swift Models.swift KeyNames.swift Target.swift EventSynth.swift Storage.swift
echo "All suites passed. Cropper end-state picture: $OUT/cropper-events.png"
