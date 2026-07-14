# EVM Hack Registry

A self-contained, offline-runnable archive of **hundreds of DeFi / EVM exploit
proof-of-concepts** spanning 2017 → 2026 across many chains.

Each exploit lives in its own standalone Foundry project, with the **actual
on-chain contract source code** (pulled from Etherscan), a captured **anvil
block-state snapshot** so it runs with no network, and an **AI-analyzed write-up
+ stack trace** explaining the vulnerability. Everything is reproducible
end-to-end from a `git clone`.

This registry is the **source of structured hack data** for the rest of the
ecosystem:

- [evm-hack-poc](https://github.com/sanbir/evm-hack-poc) — shareable ZIP archives
  generated from this data (same dataset as [crypto.training/hacks](https://crypto.training/hacks/))
- [evm-hack-analyzer](https://github.com/sanbir/evm-hack-analyzer) — in-browser
  debugger that loads those ZIPs (and can annotate / re-export research PoCs)

```bash
git clone git@github.com:sanbir/evm-hack-registry.git
cd evm-hack-registry

# run one PoC fully offline (anvil serves the chain state from a committed snapshot)
_shared/run-poc/run_poc.sh 2018-04-BEC_exp -vvvvv

# run all PoCs in parallel
_shared/run-poc/run_all.sh
```

No RPC keys, no archive node, no internet required at run time.

## Ecosystem

| Project | Role |
|---------|------|
| [evm-hack-registry](https://github.com/sanbir/evm-hack-registry) (this repo) | Source registry / structured hack data |
| [evm-hack-analyzer](https://github.com/sanbir/evm-hack-analyzer) | Analyzer UI & tooling to inspect and annotate exploits |
| [evm-hack-poc](https://github.com/sanbir/evm-hack-poc) | Shareable PoC ZIP archives for the community |
| [crypto.training/hacks](https://crypto.training/hacks/) | Public browsable mirror of this dataset |

## Why this exists

This registry is a derivative of — and gratefully built upon —
[**SunWeb3Sec/DeFiHackLabs**](https://github.com/SunWeb3Sec/DeFiHackLabs), the excellent
community collection of DeFi hack PoCs. DeFiHackLabs is an invaluable resource, but it is hard
to actually *run and study* its PoCs:

- **Archived nodes required.** The PoCs fork on-chain state at historical blocks via live RPCs.
  Reproducing them needs an **archive** node for every chain (mainnet, BSC, Arbitrum, Optimism,
  Base, Polygon, Avalanche, Fantom, Gnosis, …) — public RPCs prune state, and free archive
  access is rare/rate-limited. Without a paid archive provider you simply cannot run most PoCs.
- **Many chains, many blocks.** Hacks span many chains, each forking at a different historical
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

We plan to expand our hack PoC research **beyond** the original DeFiHackLabs set.
Your contributions are really welcomed and much appreciated — see
[evm-hack-poc](https://github.com/sanbir/evm-hack-poc) and
[evm-hack-analyzer](https://github.com/sanbir/evm-hack-analyzer) for the community
contribution path (analyze → annotate → ZIP → PR).

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
5. **Analyzed the stack traces with AI.** Each PoC has a `<Name>_exp.md` write-up explaining the
   vulnerability, the attack flow, and the key contracts — generated from the `-vvvvv` trace.

All artifacts are preserved and viewable/runnable offline:

| Artifact | What it is |
|---|---|
| `src/`, `test/`, `sources/` | exploit harness + Etherscan-fetched victim contracts |
| `anvil_state.json` | on-chain block state (anvil snapshot) — runs offline |
| `output.txt` | reference `forge test` trace |
| `<Name>_exp.md` | AI-analyzed write-up (root cause, attack flow, contracts) |

Regenerable dumps such as `forge_trace.json`, per-folder runner `20*.json`, and
`attack_tx.json` are **not** committed (see `.gitignore`).

## How to run

```bash
# one PoC, fully offline (verbose trace)
_shared/run-poc/run_poc.sh 2021-08-PolyNetwork_exp -vvvvv

# one PoC, default
_shared/run-poc/run_poc.sh 2021-08-PolyNetwork_exp

# all PoCs in parallel (bounded by CPU cores)
_shared/run-poc/run_all.sh

# compare a run against each PoC's expected output.txt
_shared/run-poc/compare_output.sh _shared/results/<timestamp>
```

Compatibility shims still work for older docs:

```bash
_shared/run_poc.sh 2018-04-BEC_exp -vvvvv
_shared/run_all.sh
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

### Analyzer / ZIP pipeline

Shared tooling under `_shared/` also builds artifacts used by the rest of the ecosystem:

| Path | Purpose |
|------|---------|
| [`_shared/run-poc/`](_shared/run-poc/) | Offline forge/anvil harness |
| [`_shared/build-poc/`](_shared/build-poc/) | Config-free builder for [evm-hack-analyzer](https://github.com/sanbir/evm-hack-analyzer) / crypto.training `PocRunnerData` JSON |

```bash
# Build a scripted runner JSON for a single PoC (empty vulnerability/story — mark in the UI)
cd _shared/build-poc && node build.mjs 2017-07-Parity_first_hack_exp
```

Packaged ZIPs for the community live in
[evm-hack-poc](https://github.com/sanbir/evm-hack-poc). Open them in
[evm-hack-analyzer](https://github.com/sanbir/evm-hack-analyzer), or browse the same
dataset at [crypto.training/hacks](https://crypto.training/hacks/).

## Status

Approximate snapshot of the committed tree (counts drift as PoCs are added):

| Metric | Count |
|--------|------:|
| PoC folders (`YYYY-MM-*`) | ~845 |
| With `anvil_state.json` | ~845 |
| `output.txt` with `Suite result: ok` | ~811 |
| Reference traces with `Suite result: FAILED` | ~24 |

- Most PoCs reproduce offline: `Suite result: ok` in the committed `output.txt`.
- A small remainder carry a documented non-passing reference trace or an incomplete
  capture (see [`_shared/README.md`](_shared/README.md)).
- **No** `[rpc_endpoints]` in any `foundry.toml`, **no** external runtime dependencies,
  **no** secrets required to run.

## Vulnerability classification

Every PoC is tagged with one or more **vulnerability classes** drawn from the
[**AuditVault**](https://github.com/AuditWare/AuditVault) smart-contract security taxonomy
(`classifications/bug/vuln/`). Tags are written as a single visible line directly under each
write-up's title, e.g.:

> **Vulnerability classes:** vuln/oracle/price-manipulation · vuln/governance/flash-loan-attack

A single exploit usually exhibits several distinct classes (the root-cause bug plus the enabling
mechanism), so multi-tagging is expected — a `·`-separated list. To find every PoC of a given class,
grep the registry:

```bash
grep -rl "vuln/oracle/price-manipulation" --include='*_exp.md' .
```

**Coverage (approx.):** ~820 write-ups carry `Vulnerability classes:` tags. Across the registry
there are **1,851+ tag instances** (avg **~2.3** classes per tagged PoC) spanning **70**
distinct `vuln/` class slugs (the AuditVault canonical set plus a handful of
classifier-assigned variants such as `vuln/business-logic/*`).

### By category

| Category | Tag count | What it covers |
|---|---:|---|
| `vuln/logic/…` | 538 | business-logic bugs (state updates, ordering, price/reward/fee/liquidation math, missing checks/validation) |
| `vuln/access-control/…` | 425 | missing auth/modifier/owner-check, uninitialized proxy/owner, leaked keys, centralization |
| `vuln/oracle/…` | 327 | price/oracle manipulation, spot-price, stale-price, single-source, TWAP, wrong feed |
| `vuln/defi/…` | 166 | AMM slippage, sandwich, fee manipulation |
| `vuln/arithmetic/…` | 112 | overflow/underflow, rounding, precision loss, decimal mismatch, div-before-mul |
| `vuln/dependency/…` | 90 | unsafe external calls, unchecked return values, upgradeable/proxy hazards |
| `vuln/governance/…` | 65 | flash-loan attacks/voting, proposal manipulation, timelock bypass |
| `vuln/reentrancy/…` | 63 | single/cross-function/cross-contract/read-only reentrancy |
| `vuln/auth/…` | 18 | signature replay/malleability/validation |
| `vuln/bridge/…` | 16 | cross-chain message spoofing, missing validation, replay |
| `vuln/input-validation/…` | 15 | missing/boundary/wrong-type input checks |
| `vuln/data/…` | 7 | uninitialized storage, missing events, wrong encoding |
| `vuln/dos/…` | 7 | frozen funds, gas-limit, griefing, lockup, unbounded loops, init constraints |
| `vuln/business-logic/…` | 2 | arbitrary-call / confused-deputy (classifier variant of `logic`) |

### By class (full breakdown)

| Class (AuditVault `vuln/` slug) | Tag count |
|---|---:|
| `vuln/access-control/missing-auth` | 254 |
| `vuln/oracle/price-manipulation` | 176 |
| `vuln/defi/slippage` | 120 |
| `vuln/oracle/spot-price` | 113 |
| `vuln/logic/state-update` | 94 |
| `vuln/logic/incorrect-state-transition` | 87 |
| `vuln/dependency/unsafe-external-call` | 74 |
| `vuln/logic/missing-check` | 71 |
| `vuln/logic/incorrect-order-of-operations` | 71 |
| `vuln/logic/missing-validation` | 68 |
| `vuln/logic/reward-calculation` | 63 |
| `vuln/governance/flash-loan-attack` | 57 |
| `vuln/access-control/missing-modifier` | 45 |
| `vuln/logic/price-calculation` | 39 |
| `vuln/arithmetic/rounding` | 35 |
| `vuln/reentrancy/single-function` | 33 |
| `vuln/arithmetic/precision-loss` | 32 |
| `vuln/access-control/broken-logic` | 30 |
| `vuln/access-control/missing-validation` | 23 |
| `vuln/defi/sandwich-attack` | 20 |
| `vuln/arithmetic/overflow` | 18 |
| `vuln/access-control/centralization` | 17 |
| `vuln/arithmetic/decimal-mismatch` | 17 |
| `vuln/defi/fee-manipulation` | 16 |
| `vuln/logic/missing-allowance` | 15 |
| `vuln/access-control/uninitialized-proxy` | 14 |
| `vuln/oracle/stale-price` | 14 |
| `vuln/auth/signature-validation` | 14 |
| `vuln/reentrancy/cross-function` | 13 |
| `vuln/logic/wrong-condition` | 13 |
| `vuln/input-validation/missing` | 13 |
| `vuln/dependency/unchecked-return-value` | 12 |
| `vuln/access-control/missing-owner-check` | 12 |
| `vuln/reentrancy/cross-contract` | 11 |
| `vuln/bridge/missing-validation` | 11 |
| `vuln/access-control/secret-exposure` | 10 |
| `vuln/logic/fee-calculation` | 10 |
| `vuln/access-control/missing-check` | 8 |
| `vuln/oracle/missing-validation` | 8 |
| `vuln/defi/flash-loan-attack` | 8 |
| `vuln/data/uninitialized` | 7 |
| `vuln/access-control/fake-account-substitution` | 7 |
| `vuln/reentrancy/read-only` | 6 |
| `vuln/arithmetic/underflow` | 6 |
| `vuln/logic/liquidation-logic` | 6 |
| `vuln/oracle/single-source` | 5 |
| `vuln/oracle/wrong-feed` | 5 |
| `vuln/access-control/uninitialized-owner` | 4 |
| `vuln/bridge/message-spoofing` | 4 |
| `vuln/dependency/upgradeable-contract` | 4 |
| `vuln/governance/proposal-manipulation` | 3 |
| `vuln/dos/griefing` | 3 |
| `vuln/governance/timelock-bypass` | 3 |
| `vuln/auth/signature-replay` | 3 |
| `vuln/oracle/manipulable-twap` | 3 |
| `vuln/dos/frozen-funds` | 2 |
| `vuln/governance/flash-loan-voting` | 2 |
| `vuln/input-validation/boundary` | 2 |
| `vuln/oracle/missing-circuit-breaker` | 2 |
| `vuln/arithmetic/rounding-direction` | 2 |
| `vuln/arithmetic/division-before-multiply` | 2 |
| `vuln/defi/price-manipulation` | 2 |
| `vuln/dos/init-constraint` | 2 |
| `vuln/access-control/proxy-storage-collision` | 1 |
| `vuln/auth/signature-malleability` | 1 |
| `vuln/business-logic/arbitrary-call` | 1 |
| `vuln/business-logic/confused-deputy` | 1 |
| `vuln/oracle/price-calculation` | 1 |
| `vuln/logic/missing-state-update` | 1 |
| `vuln/bridge/replay` | 1 |

> Tag counts are instances, not PoCs — a PoC tagged with N classes contributes N to the total.
> Classes reflect each exploit's root cause and primary enabling mechanism as described in the
> write-up; they are classifier-assigned labels, not formal audit verdicts. Category totals above
> are from the last full classification pass and may lag the latest PoC count.

## Credits

Built on top of [**SunWeb3Sec/DeFiHackLabs**](https://github.com/SunWeb3Sec/DeFiHackLabs) —
many thanks to its maintainers and contributors for assembling the original PoC collection that
this registry organizes, completes, and makes offline-runnable.

Vulnerability class labels use the [AuditVault](https://github.com/AuditWare/AuditVault) taxonomy.

## License

Same as the source — see the individual PoCs and [DeFiHackLabs](https://github.com/SunWeb3Sec/DeFiHackLabs)
for licensing.

## Disclaimer

These materials are for **educational and defensive security research only**.

- Do not use this content to attack live systems or steal funds.
- Always follow applicable law and responsible disclosure practices.
- Reproducing historical exploits should be done in local / forked environments only.
