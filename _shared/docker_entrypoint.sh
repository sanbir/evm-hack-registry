#!/bin/bash
# Docker entrypoint for evm-hack-registry.
#
# Usage (via `docker run`):
#   docker run --rm evm-hack-registry                         # run ALL POCs in parallel
#   docker run --rm evm-hack-registry 2026-06-ATM_LP_Burn_exp # run ONE POC
#   docker run --rm evm-hack-registry -vvvvv 2026-06-ATM_LP_Burn_exp  # one POC, verbose
#
# Heuristic: if the first arg names an existing POC folder, run that single POC
# (passing any remaining args to forge); otherwise run all POCs in parallel.
set -u

REG="/registry"
SHARED="$REG/_shared"
cd "$REG"

if [ "$#" -ge 1 ] && [ -d "$REG/$1" ]; then
    FOL="$1"; shift
    exec "$SHARED/run_poc.sh" "$FOL" "$@"
else
    # No specific POC: run them all in parallel. In a container, use all CPUs.
    exec "$SHARED/run_all.sh" "$(nproc)"
fi
