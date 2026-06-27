#!/bin/bash
# Run every POC offline via anvil, in parallel, with per-POC isolation.
#
# Each POC is run by run_poc.sh (own anvil on an OS-assigned port). Parallelism is
# capped at the given max (default: half the CPU cores — Solidity compile dominates).
#
# Usage: run_all.sh [max_parallel] [output_dir]
set -u

SHARED="$(cd "$(dirname "$0")" && pwd)"
REG="$(cd "$SHARED/.." && pwd)"
if [ -n "${1:-}" ]; then MAX="$1"; else MAX=$(( $(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4) / 2 )); fi
OUT="${2:-$SHARED/results/$(date +%Y%m%d_%H%M%S)}"
mkdir -p "$OUT"

cd "$REG"
# runnable POCs = those with anvil_state.json (portable: no mapfile, works on bash 3.2)
POCS=()
for d in [0-9]*/; do
    [ -f "$d/anvil_state.json" ] && POCS+=("${d%/}")
done
total=${#POCS[@]}
echo "running $total POCs (parallel=$MAX) -> $OUT"

: > "$OUT/summary.txt"

# write the runnable list to a file, then use xargs -P for robust bounded parallelism.
LIST="$OUT/.runnable.txt"
printf '%s\n' "${POCS[@]}" > "$LIST"

# Each POC is handled by _worker.sh (standalone script; no function-export fragility).
cat "$LIST" | xargs -P "$MAX" -I{} "$SHARED/_worker.sh" {} "$OUT" "$SHARED" >>"$OUT/summary.txt"
rm -f "$LIST"

# tally
pass=$(grep -c '^PASS' "$OUT/summary.txt" || true)
fail=$(grep -c '^FAIL' "$OUT/summary.txt" || true)
nostate=$(for d in [0-9]*/; do [ -f "$d/anvil_state.json" ] || echo x; done | wc -l | tr -d ' ')
echo ""
echo "=== SUMMARY ==="
echo "runnable: $total"
echo "PASS: $pass"
echo "FAIL: $fail"
echo "no-state (skipped, pruned chains): $nostate"
echo "summary: $OUT/summary.txt"
