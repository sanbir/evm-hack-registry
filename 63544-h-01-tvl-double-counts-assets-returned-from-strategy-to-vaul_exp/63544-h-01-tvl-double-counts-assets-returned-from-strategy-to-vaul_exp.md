# Elytra: receiveFromStrategy increments the vault's claimableAssets without decrementing the deposi

> **Vulnerability classes:** vuln/unfair-mint · vuln/price
>
> **Reproduction:** a faithful minimal reproduction of the vulnerable finding — the vulnerable function is reproduced **verbatim** (marked `@>`) with faithful minimal doubles; local deploy, no fork.

<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/63544-h-01-tvl-double-counts-assets-returned-from-strategy-to-vaul.md -->

## Root cause

receiveFromStrategy increments the vault's claimableAssets without decrementing the deposit pool's assetsAllocatedToStrategies, so getTotalAssetTVL double-counts the returned assets: it reports 200e18 TVL while the protocol truly holds only 100e18 (a 100e18 phantom over-report that inflates the elyAsset mint/redeem price).

```solidity
    /// @param asset Asset address
    /// @param amount Amount received
    function receiveFromStrategy(address asset, uint256 amount) external onlyStrategy {
        claimableAssets[asset] += amount; // @> increments vault claimable but never decrements ElytraDepositPoolV1.assetsAllocatedToStrategies -> TVL double-count
        emit AssetsReceivedFromStrategy(asset, amount);
    }
```

## Why it's exploitable here

receiveFromStrategy increments the vault's claimableAssets without decrementing the deposit pool's assetsAllocatedToStrategies, so getTotalAssetTVL double-counts the returned assets: it reports 200e18 TVL while the protocol truly holds only 100e18 (a 100e18 phantom over-report that inflates the elyAsset mint/redeem price).

## Attack path

```mermaid
flowchart TD
  S0["VULN step 1"]
  H["receiveFromStrategy increments the vault's claimableAssets without dec"]
  S0 --> H
```

## Marked-line walkthrough (Playground)

The EVM Playground pins each step to the exact executed source line in `0xbd4fd5a3ce…`:

1. **L108** — VULN step 1: increments vault claimable but never decrements ElytraDepositPoolV1.assetsAllocatedToStrategies -> TVL double-count

## PoC

Registry (Foundry, local deploy — verbatim vulnerable source + harm-asserting test + negative control):

```bash
cd 63544-h-01-tvl-double-counts-assets-returned-from-strategy-to-vaul_exp
forge test -vvv
```

The browser Playground replays the same synthetic opcode-for-opcode and measures the harm: **receiveFromStrategy increments the vault's claimableAssets without decrementing the deposit pool's assetsAllocatedToStrategies, so getTotalA**. Both gates are green (registry `forge test` PASS + Playground `_verify-poc` **VERDICT: PASS**).
