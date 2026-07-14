# build-poc — Offline crypto.training poc-data builder

Produces the **same JSON shape** as
[`crypto-training/public/poc-data/<slug>.json`](https://github.com/sanbir/crypto-training)
(`PocRunnerData` — see crypto-training `docs/poc-data-json-standard.md`).

Loadable by both:

- [evm-hack-analyzer](https://github.com/sanbir/evm-hack-analyzer) (scripted path)
- crypto.training `PocPlayground`

## How crypto-training builds those files

Producer: `crypto-training/scripts/build-poc-runner-data.mjs`  
Spec: `crypto-training/docs/poc-data-json-standard.md`  
Shape: `PocRunnerData` consumed by `recordExploit.ts` (browser EVM, no RPC).

| Input | Output field |
|-------|----------------|
| Hand-authored `scripts/poc-configs/<slug>.mjs` | attacker, callScript **or** exploitContract, labels, expected, setup, vulnerability, story, profitToken |
| Registry `anvil_state.json` | `accounts`, `block` |
| Foundry artifact (`forge build`) | `exploitContract.abi/bytecode`, `exploitSource` |
| Etherscan verified source | `contractSources` (pc→line maps) |

Config fields that never appear in the JSON: `folder`, `testFile`, `exploitContractName`,
`constructorArgTypes`, `syntheticExploit`, `maxContractSourceBytes`.

## How this script does the same (offline, config-free)

| Input | Output field |
|-------|----------------|
| `_shared/run-poc/run_poc.sh <folder> --json -vvv` | **callScript** (depth-1 CALLs with raw `data`) **or** **exploitContract** (when forge does `new Helper(); helper.f()`) |
| `anvil_state.json` | `accounts`, `block` (hex, same as CT) |
| forge test caller not in dump | injected EOA account with 100 ETH |
| `sources/*/_meta.json` + `*.sol` | `labels`, `contractSources` via offline compile-match |
| — | `vulnerability: null`, `story: []` (mark later in the UI) |
| — | `expected.profitWei: "0"`, native ETH `profitToken` (placeholder) |

**No Etherscan. No RPC. No per-hack configs. No attack-tx hash.**

### Attack mode selection (mirrors CT)

1. **callScript** — test body only calls pre-existing addresses (BEC, Parity, Poly). CT configs use `sig`+`args`; we emit raw `data` (also valid in `recordExploit`).
2. **exploitContract** — test deploys a helper (`CREATE` depth 1) then calls it. Matched to `out/<file>/<Contract>.json` bytecode; `attackFunction`/`attackArgs` decoded from the CALL.

```
<folder>/
  anvil_state.json          # required
  test/*.sol                # forge exploit
  sources/                  # optional offline verified sources
  forge_trace.json          # written by builder
  <slug>.json               # ← OUTPUT (PocRunnerData)
```

## Prerequisites

- Node.js ≥ 20
- Foundry (`forge`, `anvil`) on `PATH`

```bash
cd _shared/build-poc
npm install
```

## Build

```bash
node build.mjs 2021-08-PolyNetwork_exp
node build.mjs 2018-04-BEC
HACKS_REGISTRY_DIR=/path/to/evm-hack-registry node build.mjs <folder>
```

## Output schema (top-level keys)

Matches crypto-training:

`slug`, `source`, `chainId`, `block`, `accounts`, `labels`, `attacker`,
`exploitContract`, `helperContracts`, `callScript`, `setup`, `gasLimits`,
`codeOverrides`, `profitToken`, `profitReceiver`, `expected`, `exploitSource`,
`contractSources`, `vulnerability`, `story`

## Annotate later

1. Drop `<slug>.json` on **Load an existing POC** in the analyzer
2. **Mark vuln** / **Mark step**
3. Re-export the annotated bundle

## Environment

| Variable | Meaning |
|----------|---------|
| `HACKS_REGISTRY_DIR` | Registry root (default: two levels above this package) |
| `FORGE_TIMEOUT_SEC` | Per-slug forge timeout (default `600`) |
| `ALLOW_FORGE_FAIL=1` | Emit JSON even if forge fails |
| `MAX_CONTRACT_SOURCE_BYTES` | Cap embedded source maps (default `10_000_000`) |

Etherscan API keys are **ignored** (deleted at process start).
