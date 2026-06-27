#!/bin/bash
# Warm Foundry RPC caches for the ~22 POCs lacking them, by running each POC's
# forge test against an archive RPC. The RPC URLs are passed in ONLY via env/args
# and are NEVER written to any file.
#
# Usage: warm_pocs.sh <rpc_overrides>
#   where rpc_overrides is a space-separated list of chain=url (e.g. "mainnet=... bsc=...")
#
# This populates ~/.foundry/cache/rpc/<chain>/<block>. It does NOT modify any POC.
set -u

SHARED="$(cd "$(dirname "$0")" && pwd)"
REG="$(cd "$SHARED/.." && pwd)"
cd "$REG"

# Build the FOUNDRY_RPC_URLS override string from args
RPCS=""
for a in "$@"; do RPCS+="$a,"; done
RPCS="${RPCS%,}"
export FOUNDRY_RPC_URLS="$RPCS"

echo "warming with FOUNDRY_RPC_URLS override (not saved to any file)"

# POCs to warm, with their chain
warm() {
    local fol="$1"
    echo "=== $fol ==="
    ( cd "$fol" && rm -rf out && timeout 180 forge test 2>&1 | grep -E "PASS|FAIL|Suite result|error" | head -3 )
}

# mainnet POCs (SHOCO already done)
warm 2023-05-HODLCapital_exp
warm 2023-05-MultiChainCapital_exp
warm 2023-09-HeavensGate_exp
warm 2023-10-MaestroRouter2_exp
warm 2026-03-Curve_LlamaLend_exp
warm 2026-05-AdsharesBridge_exp
warm 2026-05-Ekubo_exp
# arbitrum
warm 2022-12-Lodestar_exp
warm 2026-01-futureswap_exp
warm 2026-05-FractalProtocol_exp
warm 2026-05-Renegade_exp
warm 2026-05-SEAToken_exp
# base
warm 2026-02-Moonwell_exp
# polygon
warm 2026-05-INKFinance_exp
echo "DONE archive-chains batch"
