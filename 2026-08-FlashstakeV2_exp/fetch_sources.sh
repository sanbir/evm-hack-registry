#!/usr/bin/env bash
# Fetch Flashstake V2 verified sources (FlashProtocol, FlashApp, FLASH, Pool).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
FS="/workspaces/RustroverProjects/drafts/crypto-training/crypto-training/docs/evm-hack-registry/fetch_sources.sh"
# shellcheck disable=SC1091
source /workspaces/RustroverProjects/drafts/crypto-training/crypto-training/docs/evm-hack-registry/ct_secrets.sh
OUT="$ROOT/sources"
mkdir -p "$OUT"
bash "$FS" 1 0x15EB0c763581329C921C8398556EcFf85Cc48275 "$OUT"
bash "$FS" 1 0xb0aeae6E204Bd95911EaD25263d7078954fb7fB0 "$OUT"
bash "$FS" 1 0x20398aD62bb2D930646d45a6D4292baa0b860C1f "$OUT"
bash "$FS" 1 0xC9fc5a6007c9801ebae1813D4D03208C4E85be44 "$OUT"
