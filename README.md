# evm-hack-registry

A self-contained, offline-runnable archive of **761 DeFi exploit proof-of-concepts** spanning
the full history of EVM hacks (2017 → 2026), across 15+ chains.

Each exploit lives in its own standalone Foundry project, comes with the **actual on-chain
contract source code** (pulled from Etherscan), a captured **anvil block-state snapshot** so it
runs with no network, and an **AI-analyzed write-up + stack trace** explaining the
vulnerability. Everything is reproducible end-to-end from a `git clone`:

```bash
git clone git@github.com:sanbir/evm-hack-registry.git
cd evm-hack-registry

# run one PoC fully offline (anvil serves the chain state from a committed snapshot)
_shared/run_poc.sh 2018-04-BEC_exp -vvvvv

# run all 761 in parallel
_shared/run_all.sh
```

No RPC keys, no archive node, no internet required.

---

## Why this exists

This registry is a derivative of — and gratefully built upon —
[**SunWeb3Sec/DeFiHackLabs**](https://github.com/SunWeb3Sec/DeFiHackLabs), the excellent
community collection of DeFi hack PoCs. DeFiHackLabs is an invaluable resource, but it is hard
to actually *run and study* its PoCs:

- **Archived nodes required.** The PoCs fork on-chain state at historical blocks via live RPCs.
  Reproducing them needs an **archive** node for every chain (mainnet, BSC, Arbitrum, Optimism,
  Base, Polygon, Avalanche, Fantom, Gnosis, …) — public RPCs prune state, and free archive
  access is rare/rate-limited. Without a paid archive provider you simply cannot run most PoCs.
- **Many chains, many blocks.** Hacks span 15+ chains, each forking at a different historical
  block. Coordinating the right chain + block + a working archive endpoint for each is tedious
  and brittle.
- **Incompatible Solidity versions.** PoCs were written for solc ranging from `0.4.x` to
  `0.8.x`, and they live together in one umbrella repo. A whole-project `forge build` fails to
  compile because the versions conflict.
- **Missing contract source code.** The exploits call into victim contracts whose bytecode is
  fetched live from the node at fork time — the source isn't in the repo, so you can't read or
  step through the vulnerable code.
- **No preserved state or traces.** Nothing is cached, so a run is neither reproducible nor
  offline-capable, and there are no saved stack traces to learn from.

The net effect: in DeFiHackLabs it is not easy to *run and analyze* the PoCs. That gap is what
this project closes.

---

## What we did

This registry takes every PoC and makes it a **first-class, self-contained, offline-runnable**
study unit:

1. **Migrated each PoC into a separate Forge test project.** One folder per exploit
   (`YYYY-MM-Name_exp/`), each with its own `foundry.toml`, `test/`, and `src/`. No version
   conflicts — every project compiles independently with its own solc.
2. **Downloaded the contract sources from Etherscan.** The actual vulnerable/victim contract
   code is committed under `sources/` (flattened, per-contract), so the exploited logic is
   readable and debuggable, not just live-fetched bytecode.
3. **Made each PoC compile with the correct Solidity version** and fork at the right archived
   block.
4. **Captured the on-chain state for anvil.** For each PoC, the exact block state needed to
   reproduce the exploit was downloaded once and converted to an `anvil --load-state` snapshot
   (`anvil_state.json`). At run time a local `anvil` serves that state — **no archived RPC node
   needed**.
5. **Analyzed the stack traces with AI.** Each PoC has a `<Name>.md` write-up explaining the
   vulnerability, the attack flow, and the key contracts — generated from the `-vvvvv` trace.

All artifacts are preserved and viewable/runnable offline:

| artifact | what it is |
|---|---|
| `src/`, `test/`, `sources/` | the exploit harness + Etherscan-fetched victim contracts |
| `anvil_state.json` | the on-chain block state (anvil snapshot) — runs offline |
| `output.txt` | the reference `forge test` trace |
| `<Name>.md` | the AI-analyzed write-up (root cause, attack flow, contracts) |

---

## How to run

```bash
# one PoC, fully offline (verbose trace)
_shared/run_poc.sh 2022-04-Beanstalk_exp -vvvvv

# one PoC, default
_shared/run_poc.sh 2022-04-Beanstalk_exp

# all 761 in parallel (bounded by CPU cores)
_shared/run_all.sh

# compare a run against each PoC's expected output.txt
_shared/compare_output.sh _shared/results/<timestamp>
```

Each PoC runs in isolation: `run_poc.sh` spins up a private `anvil` (on an OS-assigned port)
loaded with that PoC's `anvil_state.json`, points `forge` at it, and tears it down — so any
number of PoCs run in parallel without colliding.

### Docker

```bash
docker build -t evm-hack-registry .
docker run --rm --network none evm-hack-registry 2018-04-BEC_exp   # one PoC, offline
docker run --rm --network none evm-hack-registry                    # all PoCs, parallel
```

The image bakes in Foundry (`forge` + `anvil`), the registry, and pre-downloaded solc
compilers, so `--network none` works.

---

## Status

**729 / 759** runnable PoCs reproduce their expected verdict offline (96%): the exploit
succeeds (or, for known-failing PoCs, reproduces the documented failure). The remainder are
limited by lazy state-capture for deeply nested exploits (see `_shared/README.md`).

- **2 PoCs** (`2022-02-Meter_exp` on moonriver, `2025-09-Kame_exp` on sei) cannot be reproduced:
  their fork blocks are pruned on every public archive node.
- **No** `[rpc_endpoints]` in any `foundry.toml`, **no** external dependencies, **no** secrets.

---

## Credits

Built on top of [**SunWeb3Sec/DeFiHackLabs**](https://github.com/SunWeb3Sec/DeFiHackLabs) —
many thanks to its maintainers and contributors for assembling the original PoC collection that
this registry organizes, completes, and makes offline-runnable.

## License

Same as the source — see the individual PoCs and [DeFiHackLabs](https://github.com/SunWeb3Sec/DeFiHackLabs)
for licensing.
