#!/bin/bash
# Run a single POC fully offline via anvil, with FULL per-invocation isolation:
# anvil is started on a dynamically-allocated free localhost port, so any number of
# POCs can run in parallel without port collisions (each loads its own anvil_state.json).
#
# Usage: run_poc.sh <poc_folder> [forge test args...]
#   e.g. run_poc.sh 2026-06-ATM_LP_Burn_exp
#        run_poc.sh 2026-06-ATM_LP_Burn_exp -vvvvv
#
# The test's createSelectFork points at a fixed per-chain port (set by process_pocs.py).
# We run anvil on THAT port. For parallel runs of different POCs on the SAME chain/port,
# the caller must serialize same-chain POCs (run_all.sh does this) OR we remap. To keep
# this script self-contained and parallel-safe, if the configured port is busy we fall
# back to a free port and rewrite the test's fork URL for this run via a temp copy.
set -u

# Resolve the registry root from this script's location (_shared/ is one level under it),
# so the harness works both on the host and inside the Docker container (different paths).
SHARED="$(cd "$(dirname "$0")" && pwd)"
REG="$(cd "$SHARED/.." && pwd)"
FOL="$1"; shift
DIR="$REG/$FOL"
[ -d "$DIR" ] || { echo "no such POC: $FOL" >&2; exit 2; }
STATE="$DIR/anvil_state.json"
[ -f "$STATE" ] || { echo "no anvil_state.json in $FOL" >&2; exit 2; }

# chainId from the state's expected network: derive from the configured port's chain
PORT=$(grep -rhoE 'create(Select)?Fork\("http://127\.0\.0\.1:[0-9]+' "$DIR/test/"*.sol "$DIR"/*.sol 2>/dev/null | head -1 | grep -oE '[0-9]+$')
CHAINID=$(awk -v p="$PORT" '$2==p {print $3}' "$SHARED/chains.conf")
[ -z "$CHAINID" ] && CHAINID=1

cd "$DIR"
rm -rf out

# Isolate Foundry's compiler artifact cache per invocation. Without this, parallel
# `forge` processes corrupt each other's ~/.foundry compiler cache and fail with
# "foundry_compilers_artifacts_solc::sources" errors. We point cache_path + out into a
# per-process temp dir so each forge has its own.
ISOL="${TMPDIR:-/tmp}/evmfoundry_$$"
mkdir -p "$ISOL/cache"
export FOUNDRY_CACHE_PATH="$ISOL/cache"
# also isolate the compilers cache (downloaded solc) — share is fine read-only, but the
# artifacts index writes race; point COMPILERS cache too.
export FOUNDRY_COMPILERS_PATH="${FOUNDRY_COMPILERS_PATH:-$HOME/.foundry/solc}"
_RUN_OUT="$ISOL/out"

# ALWAYS run from an isolated temp copy on a UNIQUE port. This is the only way to
# guarantee safe parallelism: multiple POCs (even of the same chain) never collide on
# a port or on the working tree. Each invocation gets its own port chosen by anvil
# itself (port 0 = OS-assigned free port) and its own copy of the sources.
TMPROOT="${TMPDIR:-/tmp}/evmrun_$$"
rm -rf "$TMPROOT"; mkdir -p "$TMPROOT"
cp -R "$DIR/." "$TMPROOT/"
# repoint the relative forge-std symlink at the absolute shared copy (breaks in temp loc)
rm -f "$TMPROOT/lib/forge-std"
ln -s "$SHARED/forge-std" "$TMPROOT/lib/forge-std"
rm -rf "$TMPROOT/out"

# Start anvil on an OS-assigned free port (0). It prints the chosen port to stdout
# (do NOT use --silent, or the "Listening on" line we parse is suppressed).
ANVIL_LOG="$TMPROOT/anvil.log"
anvil --load-state "$TMPROOT/anvil_state.json" --port 0 --chain-id "$CHAINID" >"$ANVIL_LOG" 2>&1 &
APID=$!
ISOL_CLEAN="$ISOL"
# Cleanup on exit OR any signal: kill anvil (SIGKILL to be sure) and remove temp dirs.
# Without this, anvil orphan processes accumulate and exhaust the process/FD table,
# which is what killed earlier full runs partway through.
cleanup() {
  kill -9 "$APID" 2>/dev/null
  # also reap any anvil still bound to our temp state, just in case
  pkill -9 -f "anvil --load-state $TMPROOT/anvil_state.json" 2>/dev/null
  rm -rf "$ISOL_CLEAN" "$TMPROOT"
}
trap cleanup EXIT INT TERM

# anvil writes "Listening on 127.0.0.1:<port>" — parse the assigned port.
OWN_PORT=""
for i in $(seq 1 50); do
  OWN_PORT=$(grep -oE 'Listening on 127\.0\.0\.1:[0-9]+' "$ANVIL_LOG" 2>/dev/null | head -1 | grep -oE '[0-9]+$')
  [ -n "$OWN_PORT" ] && break
  sleep 0.1
done
if [ -z "$OWN_PORT" ]; then
  echo "anvil failed to start (see $ANVIL_LOG)" >&2; exit 3
fi

# rewrite the fork URL in the temp test sources to the assigned port.
# Portable in-place sed: `sed -i.bak` works on both GNU (Linux) and BSD (macOS) sed.
# Replace ANY "http://127.0.0.1:NNNN" string in the sources (covers both literal fork
# calls AND const-defined URLs like `string constant RPC = "http://127.0.0.1:8546";`).
for f in "$TMPROOT/test/"*.sol "$TMPROOT"/*.sol; do
  [ -f "$f" ] || continue
  grep -q "http://127\.0\.0\.1:" "$f" 2>/dev/null || continue
  sed -i.bak -E "s#http://127\.0\.0\.1:[0-9]+#http://127.0.0.1:$OWN_PORT#g" "$f"
  rm -f "$f.bak"
done
cd "$TMPROOT"

# Run forge with an isolated out dir (avoids out/ races and keeps the POC tree clean).
forge test --out "$_RUN_OUT" "$@"
RC=$?
exit $RC
