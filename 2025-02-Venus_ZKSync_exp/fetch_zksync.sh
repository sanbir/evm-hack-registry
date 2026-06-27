#!/usr/bin/env bash
# Usage: fetch_zksync.sh <address> <out_base_dir>
# Fetch verified source from zkSync Era native block explorer (Etherscan-compatible API).
set -uo pipefail
ADDR="$1"; OUT="$2"
TMP="$(mktemp)"
curl -s --max-time 40 "https://block-explorer-api.mainnet.zksync.io/api?module=contract&action=getsourcecode&address=${ADDR}" -o "$TMP" || true
[ -s "$TMP" ] || { echo "FETCH_FAIL $ADDR no-response"; rm -f "$TMP"; exit 0; }
python3 - "$ADDR" "$OUT" "$TMP" <<'PY'
import sys, json, os
addr, outbase, tmp = sys.argv[1:4]
try:
    d = json.load(open(tmp))
except Exception as e:
    print("FETCH_FAIL", addr, "parse", e); sys.exit(0)
if d.get("status") != "1":
    print("FETCH_FAIL", addr, str(d.get("result"))[:80]); sys.exit(0)
r = d["result"][0]
name = (r.get("ContractName") or "").strip() or "Unknown"
# strip path prefix like "@openzeppelin/.../BeaconProxy.sol:BeaconProxy"
short = name.split(":")[-1].split("/")[-1].replace(".sol","")
sc = r.get("SourceCode", "")
if not sc:
    print("UNVERIFIED", addr); sys.exit(0)
outdir = os.path.join(outbase, f"{short}_{addr[2:8]}")
os.makedirs(outdir, exist_ok=True)
def w(fn, content):
    safe = fn.replace("/", "_").lstrip("@_") or "src.sol"
    open(os.path.join(outdir, safe), "w").write(content)
nfiles=0
try:
    if sc.startswith("{{") and sc.endswith("}}"):
        for fn, v in json.loads(sc[1:-1]).get("sources", {}).items():
            w(fn, v["content"]); nfiles+=1
    elif sc.lstrip().startswith("{") and '"sources"' in sc[:300]:
        for fn, v in json.loads(sc).get("sources", {}).items():
            w(fn, v["content"]); nfiles+=1
    else:
        w(short + ".sol", sc); nfiles=1
except Exception:
    w(short + ".sol", sc); nfiles=1
open(os.path.join(outdir, "_meta.json"), "w").write(json.dumps({
    "address": addr, "name": name, "compiler": r.get("CompilerVersion"),
    "optimizer": r.get("OptimizationUsed"), "runs": r.get("Runs"),
    "proxy": r.get("Proxy"), "implementation": r.get("Implementation"),
}, indent=2))
print(f"OK {short} {addr} ({nfiles} files) -> {outdir}")
PY
rm -f "$TMP"
