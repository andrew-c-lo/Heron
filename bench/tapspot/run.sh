#!/bin/bash
# Tap-spot safety (see spot.swift). Uses the local eval data in bench/unstuck/data.
# Optional: run.sh <folder of stuck screens> <x,y,windowW,windowH> to also check live screens.
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT="$(mktemp -d)"
SRC=Sources/Heron
sed 's/^@main//' $SRC/App.swift > "$OUT/App-no-main.swift"
cp bench/tapspot/spot.swift "$OUT/main.swift"
swiftc -O -o "$OUT/spot" $(ls $SRC/*.swift $SRC/Views/*.swift | grep -v '/App.swift$') "$OUT/App-no-main.swift" "$OUT/main.swift" 2>&1 | grep -E "error" || true
"$OUT/spot" bench/unstuck/data bench/tapspot/results "$@"
