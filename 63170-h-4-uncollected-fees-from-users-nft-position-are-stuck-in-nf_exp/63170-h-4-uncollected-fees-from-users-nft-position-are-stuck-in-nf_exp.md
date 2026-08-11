# Ammplify: A user's 100+100 uncollected UniV3 position fees are collected by the decomposer and swept

> **Vulnerability classes:** vuln/locked-funds · vuln/unfair-mint · vuln/reward-accounting
>
> **Reproduction:** a faithful minimal reproduction of the vulnerable finding — the vulnerable function is reproduced **verbatim** (marked `@>`) with faithful minimal doubles; local deploy, no fork.

<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/63170-h-4-uncollected-fees-from-users-nft-position-are-stuck-in-nf.md -->

## Root cause

A user's 100+100 uncollected UniV3 position fees are collected by the decomposer and swept to caller==NFTManager, but decomposeAndMint never forwards them, so the user permanently loses those fees (stranded in NFTManager).

```solidity
        _currentTokenRequester = msg.sender;

        // Decompose the Uniswap V3 position
        assetId = DECOMPOSER.decompose(positionId, isCompounding, minSqrtPriceX96, maxSqrtPriceX96, rftData);

        // Clear the token requester context
```

## Why it's exploitable here

A user's 100+100 uncollected UniV3 position fees are collected by the decomposer and swept to caller==NFTManager, but decomposeAndMint never forwards them, so the user permanently loses those fees (stranded in NFTManager).

## Attack path

```mermaid
flowchart TD
  S0["VULN step 1"]
  S1["VULN step 2"]
  H["A user's 100+100 uncollected UniV3 position fees are collected by the "]
  S0 --> S1
  S1 --> H
```

## Marked-line walkthrough (Playground)

The EVM Playground pins each step to the exact executed source line in `0xbd4fd5a3ce…`:

1. **L201** — VULN step 1: swept uncollected fees now sit in NFTManager; decomposeAndMint never forwards them to msg.sender (no residual transfer, RFTPayer unused)
2. **L214** — VULN step 2: swept uncollected fees now sit in NFTManager; decomposeAndMint never forwards them to msg.sender (no residual transfer, RFTPayer unused)

## PoC

Registry (Foundry, local deploy — verbatim vulnerable source + harm-asserting test + negative control):

```bash
cd 63170-h-4-uncollected-fees-from-users-nft-position-are-stuck-in-nf_exp
forge test -vvv
```

The browser Playground replays the same synthetic opcode-for-opcode and measures the harm: **A user's 100+100 uncollected UniV3 position fees are collected by the decomposer and swept to caller==NFTManager, but decomposeAndMint never**. Both gates are green (registry `forge test` PASS + Playground `_verify-poc` **VERDICT: PASS**).
