# build-poc — Config-free PoC JSON builder

Produces a **native [evm-hack-analyzer](https://github.com/sanbir/evm-hack-analyzer) POC**
(`kind: "evm-hack-analyzer-poc"`) from any [evm-hack-registry](https://github.com/sanbir/evm-hack-registry)
slug folder.

**No per-hack configs. No AI. No hardcoded secrets.** New slugs work as soon as
they have `anvil_state.json` (and preferably `sources/` + an attack-tx comment).

```
<folder>/                          # e.g. 2017-07-Parity_first_hack_exp/
  anvil_state.json                 # required
  test/*.sol  *.md                 # attack-tx hash + chain hints
  sources/                         # optional offline verified sources
  attack_tx.json                   # optional; auto-created on first RPC fetch
  <slug>.json                      # ← OUTPUT (slug = folder without _exp)
```

## Prerequisites

- Node.js ≥ 20
- Optional: a public/archive JSON-RPC URL **only if** `attack_tx.json` is not
  already in the folder (fetched once, then cached for offline rebuilds)

```bash
cd _shared/build-poc
npm install
```

## Build one hack

```bash
# Fully offline when attack_tx.json already exists:
node build.mjs 2017-07-Parity_first_hack_exp

# First time (fetch + cache attack_tx.json):
ETH_RPC_URL=https://your.archive.rpc node build.mjs 2017-07-Parity_first_hack

# Any clone location:
HACKS_REGISTRY_DIR=/path/to/evm-hack-registry node build.mjs <folder>
```

Output: `$HACKS_REGISTRY_DIR/<folder>/<slug>.json`

## What is in the JSON

| Field | Source |
|-------|--------|
| `accounts`, `block` | `anvil_state.json` |
| `tx` | `attack_tx.json` (or one-shot RPC fetch) |
| `contractSources` | offline compile-match from `sources/` (+ optional Etherscan cache) |
| `labels` | `sources/*/_meta.json` names |
| `vulnerability`, `story` | **always empty** — mark later in the UI |

## Annotate in the analyzer

1. `npm run dev` in [evm-hack-analyzer](https://github.com/sanbir/evm-hack-analyzer)
2. Drop `<slug>.json` onto **Load an existing POC**
3. **Mark vuln** / **Mark step** on source lines
4. **⬇ poc.json** to re-export the full annotated artifact

## Environment

| Variable | Required | Meaning |
|----------|----------|---------|
| `HACKS_REGISTRY_DIR` | no | Registry root (default: two levels above this package) |
| `ETH_RPC_URL` / `RPC_URL` / `<CHAIN>_RPC_URL` | only if no `attack_tx.json` | Fetch attack-tx envelope once |
| `SOURCE_CACHE_DIR` | no | Full Etherscan response cache for source maps |
| `ETHERSCAN_API_KEY` | no | Online source fetch when local `sources/` is incomplete |

Never commit API keys or RPC URLs into this package.

## Attack-tx discovery

The builder scans `test/*.sol` and `*.md` for:

- explorer links: `etherscan.io/tx/0x…`, `bscscan.com/tx/0x…`, …
- comments: `// Attack tx: 0x…`
- `bytes32 …Tx… = 0x…` constants

Chain is taken from `createSelectFork("…")` / localhost port mapped via
`_shared/run-poc/chains.conf`.
