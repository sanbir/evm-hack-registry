# `_shared/` — shared tooling for this registry

| Path | Purpose |
|------|---------|
| **[run-poc/](run-poc/)** | Offline forge/anvil harness: run one or all Foundry exploit PoCs, Docker entrypoint, state conversion helpers |
| **[build-poc/](build-poc/)** | Config-free builder for native [evm-hack-analyzer](https://github.com/sanbir/evm-hack-analyzer) JSON artifacts |

## Quick start

```bash
# Run a Foundry PoC offline (anvil + forge)
_shared/run-poc/run_poc.sh 2018-04-BEC_exp -vvvvv
# shims still work for older docs:
_shared/run_poc.sh 2018-04-BEC_exp -vvvvv

# Build analyzer POC JSON (empty vulnerability/story — mark in the UI)
cd _shared/build-poc && node build.mjs 2017-07-Parity_first_hack_exp
```
