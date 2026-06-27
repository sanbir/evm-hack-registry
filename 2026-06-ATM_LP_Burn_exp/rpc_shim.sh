#!/bin/bash
# rpc_shim.sh — stateless offline RPC shim for Foundry fork tests.
#
# Serves ONLY the calls Foundry makes at fork creation that cannot be served
# from Foundry's own RPC cache:
#   eth_chainId, net_version, eth_gasPrice, eth_blockNumber, eth_getBlockByNumber
# All account/storage state is served by Foundry from its own cache (eth_rpc_cache_path).
#
# The shim is stateless and deterministic per (port, block): it has no per-request
# mutable state, so it is safe to share across many concurrent `forge` processes.
#
# One TCP listener per chain on a dedicated localhost port. For each accepted
# connection we read the HTTP/JSON-RPC request, build a fixed response from the
# pre-extracted block header for that chain, and write it back. We use only tools
# that ship with macOS (bash, nc, mkfifo, read, printf) — no python/perl/node/CLT.
#
# Layout expected next to this script:
#   chains/<CHAIN>.conf   -> lines:  CHAIN=<name>  CHAINID=<hex>  PORT=<n>
#   block_headers/<CHAIN> -> the pre-extracted JSON block object for that chain
#   (CHAIN here is the directory name used in ~/.foundry/cache/rpc/<CHAIN>/<block>)
#
# Usage:
#   rpc_shim.sh start [chain ...]   # start listeners for given chains (default: all)
#   rpc_shim.sh stop                # stop all listeners started by this script
#   rpc_shim.sh status              # show running listeners
#
# Requires the env var SHIM_DIR pointing at this script's directory (set automatically).

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
CONF_DIR="$HERE/chains"
HDR_DIR="$HERE/block_headers"
PID_DIR="$HERE/.pids"
mkdir -p "$PID_DIR"

# ----------------------------------------------------------------------------
# Per-connection request handling lives in the SEPARATE script rpc_handle.sh
# (see that file for the JSON-RPC dispatch logic). It is invoked by each worker
# as its own process so fifo fd ownership is unambiguous — see start_port below.
# ----------------------------------------------------------------------------


# ----------------------------------------------------------------------------
# One listener loop per port. Accepts connections serially; each connection is
# handled full-duplex via a pair of fifos so we can read-then-write.
# ----------------------------------------------------------------------------
# ----------------------------------------------------------------------------
# Per-port acceptor: a small pool of workers, each with its OWN fifo pair, all
# competing to accept() on the same port. Per-worker fifos are essential: a shared
# fifo would interleave bytes from different connections and garble the streams.
#
# Why a pool and not a single loop: BSD `nc -l` accepts exactly ONE connection then
# exits, so a single-loop listener has a restart gap between connections. Foundry
# fires its 3 fork-init calls (eth_gasPrice/eth_getBlockByNumber/eth_chainId) in
# rapid succession; during that gap the next connect() is refused and the fork
# aborts. With N workers, while one worker is mid-connection, another worker's
# `nc -l` is already accept()ing the next connection — no refusal gap.
# ----------------------------------------------------------------------------
WORKERS="${RPC_SHIM_WORKERS:-4}"

start_port() {
    local chain="$1" chainid_hex="$2" port="$3"
    local base="$PID_DIR/port_${port}"
    local handler="$HERE/rpc_handle.sh"

    # worker: $1=id. Own fifo pair, own accept loop. Calls rpc_handle.sh as a SEPARATE
    # process so fifo fd ownership is clean (its exit closes its fifo fds, letting nc
    # see EOF and close the socket so the HTTP client completes).
    worker() {
        local wid="$1"
        local fa="$base.in.$wid" fb="$base.out.$wid"
        rm -f "$fa" "$fb"; mkfifo "$fa" "$fb"
        exec 3<>"$fa" 4<>"$fb"
        while :; do
            # nc -l: stdin=fb (response->client), stdout=fa (client request->handler)
            nc -l "$port" <&4 >&3 2>/dev/null &
            local np=$!
            "$handler" "$chain" "$chainid_hex" <&3 >&4
            exec 4>&-                # close our fout so nc's stdin EOFs -> socket closes -> client completes
            wait "$np" 2>/dev/null
            exec 4<>"$fb"            # reopen for the next accepted connection
        done
    }

    # spawn the worker pool under one supervisor subshell
    (
        for i in $(seq 1 "$WORKERS"); do
            worker "$i" &
        done
        wait
    ) >/dev/null 2>&1 &
    local loopid=$!
    echo "$loopid" > "$PID_DIR/port_${port}.pid"
    echo "started $chain (chainId=$chainid_hex) on 127.0.0.1:$port  pid=$loopid (workers=$WORKERS)"
}

cmd_start() {
    local chains=("$@")
    [ ${#chains[@]} -eq 0 ] && while IFS= read -r f; do
        chains+=("$(basename "$f" .conf)")
    done < <(ls "$CONF_DIR"/*.conf 2>/dev/null)

    for chain in "${chains[@]}"; do
        local conf="$CONF_DIR/$chain.conf"
        [ -f "$conf" ] || { echo "skip $chain: no conf"; continue; }
        local chainid_hex port
        chainid_hex="$(grep -E '^CHAINID=' "$conf" | head -1 | cut -d= -f2)"
        port="$(grep -E '^PORT=' "$conf" | head -1 | cut -d= -f2)"
        [ -z "$chainid_hex" ] || [ -z "$port" ] && { echo "skip $chain: bad conf"; continue; }
        [ -f "$HDR_DIR/$chain" ] || { echo "skip $chain: no block header"; continue; }
        start_port "$chain" "$chainid_hex" "$port"
    done
}

cmd_stop() {
    # Order matters: kill the supervisors first so they stop respawning workers,
    # then reap the worker `nc -l <port>` listeners and handler scripts.
    # `pkill -f rpc_shim.sh` would match THIS stop invocation, so match only the
    # `start` form.
    pkill -f "rpc_shim.sh start" 2>/dev/null
    pkill -f "rpc_shim.sh' start" 2>/dev/null

    # Kill any worker nc listeners on our configured ports (also covers orphans
    # left by previous/crashed runs).
    for conf in "$CONF_DIR"/*.conf; do
        [ -f "$conf" ] || continue
        local port
        port="$(grep -E '^PORT=' "$conf" | head -1 | cut -d= -f2)"
        [ -n "$port" ] && pkill -f "nc -l $port" 2>/dev/null
    done
    pkill -f "rpc_handle.sh" 2>/dev/null

    rm -f "$PID_DIR"/*.pid 2>/dev/null
    # SIGKILL any stragglers blocked on fifo reads
    sleep 0.2
    for conf in "$CONF_DIR"/*.conf; do
        [ -f "$conf" ] || continue
        local port
        port="$(grep -E '^PORT=' "$conf" | head -1 | cut -d= -f2)"
        [ -n "$port" ] && pkill -9 -f "nc -l $port" 2>/dev/null
    done
    pkill -9 -f "rpc_handle.sh" 2>/dev/null
    pkill -9 -f "rpc_shim.sh start" 2>/dev/null
    echo "stopped"
}

cmd_status() {
    for pf in "$PID_DIR"/*.pid; do
        [ -f "$pf" ] || continue
        local pid port
        pid="$(cat "$pf")"
        port="$(basename "$pf" .pid | sed 's/port_//')"
        if kill -0 "$pid" 2>/dev/null; then
            echo "port $port: RUNNING (pid $pid)"
        else
            echo "port $port: dead"
        fi
    done
}

case "${1:-}" in
    start) shift; cmd_start "$@" ;;
    stop) cmd_stop ;;
    status) cmd_status ;;
    *) echo "usage: $0 {start [chain ...] | stop | status}"; exit 1 ;;
esac
