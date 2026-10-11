#!/bin/bash
# Window-level checks: builds the debug binary, runs it with FEATHER_UITEST set (UITestHarness.swift drives the
# window through its scenarios, prints PASS/FAIL lines and PNGs, then exits), and fails on any FAIL.
#   tools/uitest.sh [output-folder]            FEATHER_UITEST_ONLY=name runs one scenario
set -uo pipefail
cd "$(dirname "$0")/.."
OUT="${1:-$(mktemp -d /tmp/feather-uitest.XXXXXX)}"
mkdir -p "$OUT"
swift build 2>&1 | grep -E "error|Build complete" || true
BIN="$(swift build --show-bin-path)/Feather"
[[ -x "$BIN" ]] || { echo "no binary"; exit 2; }
# The harness quits by itself; if the window never appears this stops it after two minutes.
FEATHER_UITEST="$OUT" FEATHER_UITEST_ONLY="${FEATHER_UITEST_ONLY:-}" "$BIN" > "$OUT/uitest.log" 2>&1 &
PID=$!
for _ in $(seq 1 120); do kill -0 $PID 2>/dev/null || break; sleep 1; done
kill $PID 2>/dev/null
grep -E "^(PASS|FAIL|SKIP|UITEST)" "$OUT/uitest.log"
echo "PNGs and log in $OUT"
! grep -q "^FAIL" "$OUT/uitest.log" && grep -q "UITEST: all passed" "$OUT/uitest.log"
