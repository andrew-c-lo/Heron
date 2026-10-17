#!/bin/bash
# Unstuck eval tools. Data (real screenshots, labels) lives in bench/unstuck/data/ and stays local.
#   bench/unstuck/run.sh candidates    list text candidates per screen + review sheets
#   bench/unstuck/run.sh collect       add screens Heron captured while you played (the "fresh" set)
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
    collect) python3 bench/unstuck/collect.py ;;
    eval) shift; "$(build eval eval.swift)" bench/unstuck/data "$@" ;;
    *) echo "usage: bench/unstuck/run.sh collect | candidates | eval [strategy …]   (EVAL_SET=fresh|practice to score one set)"; exit 2 ;;
esac
