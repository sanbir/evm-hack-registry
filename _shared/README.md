# evm-hack-registry — offline test runner

All 761 DeFi-exploit reproduction POCs run **fully offline** via `anvil`, with no
network and no external RPC. Each POC forks from a local `anvil` instance loaded
with the POC's committed on-chain state (`anvil_state.json`).

## Why anvil (the key insight)

`forge test` forks an external chain via `vm.createSelectFork(url, block)`. Even with
Foundry's RPC cache present, Foundry **always** makes 3 live RPC calls at fork creation
(`eth_chainId`, `eth_gasPrice`, `eth_getBlockByNumber`). So a fork cannot run purely
from Foundry's cache alone — something must serve those calls.

This harness uses `anvil` (shipped with Foundry) as that "something": each POC's
captured on-chain state is converted to an anvil `--load-state` JSON, anvil serves
**every** RPC call (headers + account/storage/code) from memory, and `forge` forks
from `http://127.0.0.1:<port>`. No network, no Foundry RPC cache needed at runtime.

## Layout

```
<POC>/
  foundry.toml       # NO [rpc_endpoints] section
  anvil_state.json   # committed; anvil loads this (block + accounts + storage + code)
  test/*.sol         # createSelectFork("http://127.0.0.1:<chain-port>", <block>)
  lib/forge-std      # -> ../../_shared/forge-std  (relative symlink)
_shared/
  forge-std/         # one real copy; all 761 POCs symlink to it (self-contained)
  chains.conf        # chain -> (port, chainId) map
  run_poc.sh         # run ONE POC offline (own anvil on an OS-assigned free port)
  run_all.sh         # run ALL POCs in parallel, bounded by CPU cores
  _worker.sh         # per-POC worker used by run_all.sh's xargs pool
  compare_output.sh  # compare a results run vs each POC's expected output.txt
  cache2anvil.py     # BUILD tool: convert a Foundry rpc cache -> anvil state JSON
  process_pocs.py    # BUILD tool: batch-convert all POCs (rewrites tests/foundry.toml)
  warm_pocs.sh       # BUILD tool: warm missing caches via archive RPCs
  handle_txhash.py   # BUILD tool: convert tx-hash-fork POCs to block forks
  docker_entrypoint.sh
Dockerfile           # self-contained image: foundry + registry, runs offline
.dockerignore
```

## Running

```bash
# one POC (offline)
_shared/run_poc.sh 2026-06-ATM_LP_Burn_exp

# one POC, verbose
_shared/run_poc.sh 2026-06-ATM_LP_Burn_exp -vvvvv

# all POCs in parallel (bounded by half the CPU cores)
_shared/run_all.sh
_shared/run_all.sh 4                       # explicit parallelism
_shared/run_all.sh 4 /path/to/outdir       # custom results dir

# compare a results run against each POC's expected output.txt
_shared/compare_output.sh _shared/results/<timestamp>
```

Each POC runs in full isolation: `run_poc.sh` copies the POC to a temp dir, starts an
anvil on an OS-assigned free port (`--port 0`), rewrites the test's fork URL to that
port, and runs `forge`. Any number of POCs can run in parallel with no port/tree
collisions.

## Docker

```bash
docker build -t evm-hack-registry .
docker run --rm --network none evm-hack-registry 2018-04-BEC_exp   # one POC, fully offline
docker run --rm --network none evm-hack-registry                    # all POCs, parallel
```

The image bakes in Foundry (`forge`+`anvil`), the registry, and pre-downloaded solc
compilers, so `--network none` works.

## Status (host verification)

Full offline run of all 759 POCs with `anvil_state.json`, compared against each POC's
expected `output.txt`:

| result | count |
|---|---|
| MATCH-pass (expected PASS → got PASS) | 719 |
| MATCH-fail (expected FAIL → got FAIL; known-failing POCs reproduced) | 10 |
| REGRESSION (expected PASS → FAIL) | 27 |
| skipped (no state — pruned chains) | 2 |

**729 / 759 (96%) reproduce their expected verdict offline.**

### The 27 regressions
The hard ceiling of reproducing lazily-captured fork state offline:
- **21 `EvmError: Revert`** — Foundry caches fork state *lazily* (only what a given run
  reads), so a cache from one execution path may miss storage/accounts that a different
  path touches. Complex flashloan/swap exploits need exact state across many contracts;
  if even one slot differs the exploit's arithmetic reverts. Each such POC's cache was
  re-warmed online to completion, but Foundry still does not capture 100% of reads.
- **3 multi-fork / multi-block** — POCs that `createFork`/`rollFork` across blocks far
  apart (e.g. safeMoon forks at 26.85M then rollForks to 26.86M). anvil `--load-state`
  provides one account-state set; spanning thousands of placeholder block headers is
  impractical, and the state differs across the gap.
- **3 other** — edge cases (genuine in-container divergence, etc.).

### The 2 permanently-blocked POCs
- `2022-02-Meter_exp` — moonriver block 1442490 is **pruned** on every public RPC.
- `2025-09-Kame_exp` — sei block 167791782 is **pruned** (earliest available ≈ 210M).

No public archive node retains this history, so these cannot be reproduced offline.

## Re-warming (build-time, needs archive RPC access)

To improve a regression's state coverage, re-run it online against an archive RPC so
Foundry captures more state, then re-convert:

```bash
# re-warm one POC (reverts test to alias, runs online, re-converts, restores localhost).
# The RPC URL is used in-process ONLY and is never written to any file.
python3 _shared/exhaustive_warm.py <poc_folder> <chain> "<archive_rpc_url>"
# e.g.
python3 _shared/exhaustive_warm.py 2025-02-HegicOptions_exp mainnet \
        "<your-archive-rpc-url>"
```

Multi-fork POCs are handled by building an anvil state that spans all detected fork
blocks (block headers for the full range, account-state at the earliest block).

## USB-portability

The registry is self-contained: copying the folder to a fresh Mac with only Foundry
installed and running `run_poc.sh <POC>` (or `run_all.sh`) works with no network and
no other dependencies. `lib/forge-std` is a relative symlink to the in-repo
`_shared/forge-std`, so there is no dependence on any external path.
```
