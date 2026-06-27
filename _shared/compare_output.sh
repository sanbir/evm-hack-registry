#!/bin/bash
# Compare offline run verdicts against the expected verdicts in each POC's output.txt.
#
# For each POC: extract the PASS/FAIL verdict (and the failure reason) from both the
# existing output.txt and the freshly-produced offline log, and report matches vs
# regressions vs expected-failures.
#
# Usage: compare_output.sh <results_dir>
set -u
SHARED="$(cd "$(dirname "$0")" && pwd)"
REG="$(cd "$SHARED/.." && pwd)"
OUT="$1"

# Extract the canonical verdict from a forge log: the [PASS]/[FAIL] line.
verdict() {
    local f="$1"
    [ -f "$f" ] || { echo "NO-LOG"; return; }
    # prefer the test result line; capture PASS or FAIL + first reason token
    grep -oE "\[(PASS|FAIL)[^]]*\][^$]*" "$f" 2>/dev/null | head -1 \
        | sed -E 's/\(gas: [0-9]+\)//' | tr -s ' ' | sed 's/ *$//' \
        | sed 's/^ *//'
}
verdict_passfail() {
    local v; v="$(verdict "$1")"
    case "$v" in
        "[PASS]"*) echo "PASS";;
        "[FAIL"*|*FAIL*) echo "FAIL";;
        "") echo "NONE";;
        *) echo "$v";;
    esac
}

echo "POC	EXPECTED	OFFLINE	STATUS"
echo "---	-------	-------	------"
match=0; expfail_match=0; regression=0; other=0
for d in "$REG"/[0-9]*/; do
    fol=$(basename "$d")
    exp="$(verdict_passfail "$d/output.txt")"
    off="$(verdict_passfail "$OUT/$fol.log")"
    [ "$off" = "NONE" ] && continue  # not run / no log
    if [ "$exp" = "PASS" ] && [ "$off" = "PASS" ]; then
        st="MATCH-pass"; match=$((match+1))
    elif [ "$exp" = "FAIL" ] && [ "$off" = "FAIL" ]; then
        st="MATCH-fail(expected-fail)"; expfail_match=$((expfail_match+1))
    elif [ "$exp" = "PASS" ] && [ "$off" = "FAIL" ]; then
        st="REGRESSION"; regression=$((regression+1))
    else
        st="other(exp=$exp off=$off)"; other=$((other+1))
    fi
    # only print non-pass to keep output readable
    [ "$st" != "MATCH-pass" ] && printf "%s\t%s\t%s\t%s\n" "$fol" "$exp" "$off" "$st"
done
echo ""
echo "=== TALLY ==="
echo "MATCH-pass (both PASS):              $match"
echo "MATCH-fail (both FAIL, expected):    $expfail_match"
echo "REGRESSION (expected PASS, got FAIL):$regression"
echo "other:                               $other"
