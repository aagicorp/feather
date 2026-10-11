#!/bin/bash
# Measures the RELEASE build: launch time, idle CPU and memory, a 3,000-file folder, expanding its tree, a
# 1.5 MB TypeScript file, keystroke cost, and what switching the API client on costs.
#   tools/perf.sh [output-folder]
set -uo pipefail
cd "$(dirname "$0")/.."
OUT="${1:-$(mktemp -d /tmp/feather-perf.XXXXXX)}"
mkdir -p "$OUT"
swift build -c release 2>&1 | grep -E "error|Build complete" || true
BIN="$(swift build -c release --show-bin-path)/Feather"
[[ -x "$BIN" ]] || { echo "no binary"; exit 2; }
START=$(python3 -c 'import time; print(time.time())')
FEATHER_PERF="$OUT" "$BIN" > "$OUT/perf.log" 2>&1 &
PID=$!
# Sample CPU while the app idles during its first scenario.
sleep 2
CPU=$(top -l 3 -s 1 -pid $PID -stats cpu 2>/dev/null | grep -E "^[0-9. ]+$" | tail -2 | awk '{s+=$1} END {printf "%.1f", s/NR}')
LEAKS=""
for _ in $(seq 1 240); do
    kill -0 $PID 2>/dev/null || break
    # Once the folder scenario has run, count leaked blocks while the app is still alive.
    if [[ -z "$LEAKS" ]] && grep -q "PERF memory-after-folder" "$OUT/perf.log"; then
        LEAKS=$(leaks "$PID" 2>/dev/null | grep -E "^Process $PID: [0-9]+ leaks? for" | sed -E 's/.*: ([0-9]+) leaks? for ([0-9]+) total leaked bytes.*/\1 leaks, \2 bytes/')
        LEAKS="${LEAKS:-unavailable}"
    fi
    sleep 1
done
kill $PID 2>/dev/null
READY=$(grep "PERF window-ready" "$OUT/perf.log" | awk '{print $3}')
python3 - "$START" "$READY" <<'PY'
import sys
start, ready = float(sys.argv[1]), float(sys.argv[2])
print(f"PERF launch-to-window {(ready - start) * 1000:.0f} ms")
PY
echo "PERF idle-cpu ${CPU:-?} %"
echo "PERF leaks ${LEAKS:-not measured}"
grep -E "^PERF" "$OUT/perf.log" | grep -v window-ready
grep -E "^FAIL" "$OUT/perf.log" || true
ls -la "$BIN" | awk '{printf "PERF release-binary %.1f MB\n", $5/1048576}'
