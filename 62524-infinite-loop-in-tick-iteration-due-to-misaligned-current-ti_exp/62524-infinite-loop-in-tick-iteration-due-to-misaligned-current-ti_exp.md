# Uniswap Hooks: A currentTick misaligned to tickSpacing makes AntiSandwichHook's verbatim `tick != current

> **Vulnerability classes:** vuln/locked-funds
>
> **Reproduction:** a faithful minimal reproduction of the vulnerable finding — the vulnerable function is reproduced **verbatim** (marked `@>`) with faithful minimal doubles; local deploy, no fork.

<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/62524-infinite-loop-in-tick-iteration-due-to-misaligned-current-ti.md -->

## Root cause

A currentTick misaligned to tickSpacing makes AntiSandwichHook's verbatim `tick != currentTick` top-of-block snapshot loop step over the target and never terminate, so _beforeSwap reverts (OOG) even under a full 30M-gas block budget — every swap on the pool is permanently bricked (liveness DoS).

```solidity
    function runCheckpoint(int24 lastTick, int24 currentTick, int24 tickSpacing) external {
        int24 step = currentTick > lastTick ? tickSpacing : -tickSpacing;

        for (int24 tick = lastTick; tick != currentTick; tick += step) { // @> misaligned currentTick is stepped over: `tick != currentTick` never becomes false -> infinite loop -> OOG / int24-overflow revert on every swap
            // liquidity/fee update reduced to a trivial, side-effectful double;
            // the real V4 PoolManager reads are irrelevant to loop termination.
```

## Why it's exploitable here

A currentTick misaligned to tickSpacing makes AntiSandwichHook's verbatim `tick != currentTick` top-of-block snapshot loop step over the target and never terminate, so _beforeSwap reverts (OOG) even under a full 30M-gas block budget — every swap on the pool is permanently bricked (liveness DoS).

## Attack path

```mermaid
flowchart TD
  S0["VULN step 1"]
  H["A currentTick misaligned to tickSpacing makes AntiSandwichHook's verba"]
  S0 --> H
```

## Marked-line walkthrough (Playground)

The EVM Playground pins each step to the exact executed source line in `0x8ea53755a6…`:

1. **L69** — VULN step 1: misaligned currentTick is stepped over: `tick != currentTick` never becomes false -> infinite loop -> OOG / int24-overflow revert on every swap

## PoC

Registry (Foundry, local deploy — verbatim vulnerable source + harm-asserting test + negative control):

```bash
cd 62524-infinite-loop-in-tick-iteration-due-to-misaligned-current-ti_exp
forge test -vvv
```

The browser Playground replays the same synthetic opcode-for-opcode and measures the harm: **A currentTick misaligned to tickSpacing makes AntiSandwichHook's verbatim `tick != currentTick` top-of-block snapshot loop step over the tar**. Both gates are green (registry `forge test` PASS + Playground `_verify-poc` **VERDICT: PASS**).
