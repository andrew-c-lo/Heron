#!/bin/bash
# Screen kind eval (see kind.swift).
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT="$(mktemp -d)"
SRC=Sources/Heron
sed 's/^@main//' $SRC/App.swift > "$OUT/App-no-main.swift"
cp bench/screenkind/kind.swift "$OUT/main.swift"
swiftc -O -o "$OUT/kind" $(ls $SRC/*.swift $SRC/Views/*.swift | grep -v '/App.swift$') "$OUT/App-no-main.swift" "$OUT/main.swift" 2>&1 | grep -E "error" || true
"$OUT/kind" bench/unstuck/data bench/screenkind/results "$@"
