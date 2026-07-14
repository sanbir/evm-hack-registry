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

# Resolve the registry root from this script's location
# (_shared/run-poc/ is two levels under it), so the harness works both on the host
# and inside the Docker container (different paths).
RUN_POC="$(cd "$(dirname "$0")" && pwd)"
REG="$(cd "$RUN_POC/../.." && pwd)"
FOL="$1"; shift
DIR="$REG/$FOL"
[ -d "$DIR" ] || { echo "no such POC: $FOL" >&2; exit 2; }
STATE="$DIR/anvil_state.json"
[ -f "$STATE" ] || { echo "no anvil_state.json in $FOL" >&2; exit 2; }

# chainId from the state's expected network: derive from the configured port's chain
PORT=$(grep -rhoE 'create(Select)?Fork\("http://127\.0\.0\.1:[0-9]+' "$DIR/test/"*.sol "$DIR"/*.sol 2>/dev/null | head -1 | grep -oE '[0-9]+$')
CHAINID=$(awk -v p="$PORT" '$2==p {print $3}' "$RUN_POC/chains.conf")
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
ln -s "$RUN_POC/forge-std" "$TMPROOT/lib/forge-std"
rm -rf "$TMPROOT/out"

# Start anvil on an OS-assigned free port (0). It prints the chosen port to stdout
# (do NOT use --silent, or the "Listening on" line we parse is suppressed).
# Run at lower priority to reduce chance of OOM-killing other work; the kernel
# may still SIGKILL on very large states (some PoCs have GB-scale in-memory state).
ANVIL_LOG="$TMPROOT/anvil.log"
nice -n 10 anvil --load-state "$TMPROOT/anvil_state.json" --port 0 --chain-id "$CHAINID" >"$ANVIL_LOG" 2>&1 &
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

# Give anvil a moment; if it died immediately (e.g. OOM on --load-state), report it.
sleep 0.2
if ! kill -0 "$APID" 2>/dev/null; then
  echo "anvil was killed immediately on launch (likely OOM / resource limit). See $ANVIL_LOG" >&2
  # Do not exit hard here — let the caller (build.mjs) decide whether to emit partial JSON.
  # We will still try the port wait (it will fail) and surface a useful exit code.
fi

# anvil writes "Listening on 127.0.0.1:<port>" — parse the assigned port.
OWN_PORT=""
for i in $(seq 1 80); do
  OWN_PORT=$(grep -oE 'Listening on 127\.0\.0\.1:[0-9]+' "$ANVIL_LOG" 2>/dev/null | head -1 | grep -oE '[0-9]+$')
  [ -n "$OWN_PORT" ] && break
  sleep 0.1
done
if [ -z "$OWN_PORT" ]; then
  # Surface the last few lines of the log for diagnosis (often contains the kill reason).
  echo "anvil failed to start or was killed (see $ANVIL_LOG)" >&2
  tail -c 2048 "$ANVIL_LOG" >&2 || true
  # Exit 3 signals "anvil problem" to build.mjs; with ALLOW_FORGE_FAIL it will still emit.
  exit 3
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
# --no-storage-caching: Foundry otherwise caches eth_getStorageAt from earlier
# online/offline runs and can serve STALE zeros for slots that anvil_state later
# corrected (seen on 2025-08-PDZ: slot 0x20 _burnToken stayed 0 → ZERO_ADDRESS).
forge test --out "$_RUN_OUT" --no-storage-caching "$@"
RC=$?
exit $RC
