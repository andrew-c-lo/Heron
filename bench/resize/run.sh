#!/bin/bash
# Resize stress test (see stress.swift). Uses the local eval data in bench/unstuck/data.
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT="$(mktemp -d)"
SRC=Sources/Heron
sed 's/^@main//' $SRC/App.swift > "$OUT/App-no-main.swift"
cp bench/resize/stress.swift "$OUT/main.swift"
swiftc -O -o "$OUT/stress" $(ls $SRC/*.swift $SRC/Views/*.swift | grep -v '/App.swift$') "$OUT/App-no-main.swift" "$OUT/main.swift" 2>&1 | grep -E "error" || true
"$OUT/stress" bench/unstuck/data bench/resize/results
