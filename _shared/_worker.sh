#!/bin/bash
# _worker.sh — run ONE POC and print "PASS/FAIL <poc>" for run_all.sh's xargs pool.
# Kept as a standalone script (not a function) so it works reliably under xargs -P
# without exporting functions (which is fragile on bash 3.2).
# Args: $1 = poc folder, $2 = output dir, $3 = _shared dir
set -u
fol="$1"; OUT="$2"; SHARED="$3"
if timeout 300 "$SHARED/run_poc.sh" "$fol" >"$OUT/$fol.log" 2>&1; then
    echo "PASS  $fol"
else
    fl=$(grep -oE "\[FAIL.*" "$OUT/$fol.log" 2>/dev/null | head -1)
    [ -z "$fl" ] && fl=$(grep -iE "error|panic|revert|unable" "$OUT/$fol.log" 2>/dev/null | head -1)
    echo "FAIL  $fol  ::  ${fl:0:110}"
fi
