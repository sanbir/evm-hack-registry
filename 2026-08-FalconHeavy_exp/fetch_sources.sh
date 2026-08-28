#!/usr/bin/env bash
# Fetch Falcon Heavy (FH) verified sources + pair + Moolah flash-loan proxy/impl.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
FS="/workspaces/RustroverProjects/drafts/crypto-training/crypto-training/docs/evm-hack-registry/fetch_sources.sh"
# shellcheck disable=SC1091
source /workspaces/RustroverProjects/drafts/crypto-training/crypto-training/docs/evm-hack-registry/ct_secrets.sh
OUT="$ROOT/sources"
mkdir -p "$OUT"
bash "$FS" 56 0xdCf0DFe0053677A67610c6d08EA1f5c78DF8cA37 "$OUT"
bash "$FS" 56 0x8f2d1A3992856a860304f1B86534B6B129Cc4df7 "$OUT"
bash "$FS" 56 0x8f73b65b4caaf64fba2af91cc5d4a2a1318e5d8c "$OUT"
bash "$FS" 56 0x9321587ea0dc8247f8f03e8696c047b2713bb79a "$OUT"
