#!/bin/bash
# Screenshots for the website and the README: builds the debug binary and runs it in screenshot mode
# (UITestHarness+Shots.swift) on this repository. One PNG per state lands in the output folder.
#   tools/shots.sh [output-folder]
set -uo pipefail
cd "$(dirname "$0")/.."
OUT="${1:-$(mktemp -d /tmp/feather-shots.XXXXXX)}"
mkdir -p "$OUT"
swift build 2>&1 | grep -E "error|Build complete" || true
BIN="$(swift build --show-bin-path)/Feather"
[[ -x "$BIN" ]] || { echo "no binary"; exit 2; }
FEATHER_SHOTS="$OUT" "$BIN" > "$OUT/shots.log" 2>&1 &
PID=$!
for _ in $(seq 1 120); do kill -0 $PID 2>/dev/null || break; sleep 1; done
kill $PID 2>/dev/null
grep -E "^(FAIL|UITEST)" "$OUT/shots.log"
ls "$OUT"/*.png 2>/dev/null | xargs -n1 basename
echo "PNGs in $OUT"
