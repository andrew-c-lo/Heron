#!/bin/bash
# Visual QA: captures every page and state at three window sizes, in light and dark, from the demo data.
#   scripts/qa-sweep.sh [out-dir]   (default: .qa/)
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:-$PWD/.qa}"
rm -rf "$OUT"
for appearance in light dark; do
    # Fresh demo data each pass (the sweep adds and removes a macro).
    scripts/make-demo.sh --build-only >/dev/null
    HERON_HOME="$PWD/.demo/home" HERON_SCREENSHOTS=1 HERON_QA_DIR="$OUT/$appearance" \
        HERON_QA_APPEARANCE="$appearance" .demo/Heron.app/Contents/MacOS/Heron >/dev/null 2>&1
done
find "$OUT" -name '*.png' | wc -l | xargs echo "pictures in $OUT:"
