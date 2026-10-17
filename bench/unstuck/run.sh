#!/bin/bash
# Unstuck eval tools. Data (real screenshots, labels) lives in bench/unstuck/data/ and stays local.
#   bench/unstuck/run.sh candidates    list text candidates per screen + review sheets
#   bench/unstuck/run.sh eval [s …]    score strategies against data/labels.json; saves results/
set -euo pipefail
cd "$(dirname "$0")/../.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
OUT="$(mktemp -d)"
SRC=Sources/Heron
sed 's/^@main//' $SRC/App.swift > "$OUT/App-no-main.swift"
build() { # name, tool source
    mkdir -p "$OUT/$1"; cp "bench/unstuck/$2" "$OUT/$1/main.swift"
    swiftc -O -o "$OUT/$1/tool" $(ls $SRC/*.swift $SRC/Views/*.swift | grep -v '/App.swift$') "$OUT/App-no-main.swift" "$OUT/$1/main.swift"
    echo "$OUT/$1/tool"
}
case "${1:-}" in
    candidates) "$(build candidates candidates.swift)" bench/unstuck/data ;;
    eval) shift; "$(build eval eval.swift)" bench/unstuck/data "$@" ;;
    *) echo "usage: bench/unstuck/run.sh candidates | eval [strategy …]"; exit 2 ;;
esac
