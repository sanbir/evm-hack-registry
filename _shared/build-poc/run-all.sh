#!/usr/bin/env bash
# Sequential full rebuild of all registry slugs → PocRunnerData JSON.
set -u
REG="$(cd "$(dirname "$0")/../.." && pwd)"
BP="$REG/_shared/build-poc"
LIST="$BP/build-all-folders.txt"
LOG="$BP/build-all-run.log"
STATUS="$BP/build-all-status.tsv"
export HACKS_REGISTRY_DIR="$REG"
export FORGE_TIMEOUT_SEC="${FORGE_TIMEOUT_SEC:-600}"
# Always emit best-effort JSON even if forge/anvil was killed (OOM, resource limits, etc.).
# callScript may be partial/empty; accounts + sources are still useful for the analyzer.
export ALLOW_FORGE_FAIL=1

cd "$BP"
total=$(grep -c . "$LIST" || true)
n=0
ok=0
fail=0
echo "[run-all] start total=$total registry=$REG" | tee -a "$LOG"
echo "[run-all] $(date -Iseconds)" | tee -a "$LOG"

while IFS= read -r folder || [[ -n "${folder:-}" ]]; do
  [[ -z "$folder" ]] && continue
  n=$((n+1))
  # Skip only if this exact run already marked it OK
  if grep -q "^${folder}"$'\t'"OK" "$STATUS" 2>/dev/null; then
    echo "[run-all] ($n/$total) SKIP already OK $folder" | tee -a "$LOG"
    ok=$((ok+1))
    continue
  fi
  echo "" | tee -a "$LOG"
  echo "[run-all] ===== ($n/$total) $folder =====" | tee -a "$LOG"
  t0=$(date +%s)
  if node build.mjs "$folder" >>"$LOG" 2>&1; then
    t1=$(date +%s)
    dt=$((t1-t0))
    printf '%s\tOK\t%ss\n' "$folder" "$dt" >> "$STATUS"
    ok=$((ok+1))
    echo "[run-all] OK $folder (${dt}s)  progress ok=$ok fail=$fail" | tee -a "$LOG"
  else
    t1=$(date +%s)
    dt=$((t1-t0))
    printf '%s\tFAIL\t%ss\n' "$folder" "$dt" >> "$STATUS"
    fail=$((fail+1))
    echo "[run-all] FAIL $folder (${dt}s)  progress ok=$ok fail=$fail" | tee -a "$LOG"
  fi
  # Give the OS a chance to reclaim memory between heavy PoCs.
  sleep 1
done < "$LIST"

echo "[run-all] DONE $(date -Iseconds) ok=$ok fail=$fail total=$total" | tee -a "$LOG"
echo "[run-all] Failed folders (for re-run):"
grep $'\tFAIL\t' "$STATUS" | cut -f1 || true
echo "[run-all] To retry only failures: grep $'\\tFAIL\\t' $STATUS | cut -f1 | xargs -I{} node build.mjs {}"