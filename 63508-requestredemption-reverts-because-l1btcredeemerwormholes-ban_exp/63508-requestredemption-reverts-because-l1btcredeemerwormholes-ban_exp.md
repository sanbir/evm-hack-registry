# Threshold: Every Wormhole tBTC redemption reverts because the redeemer's satoshi balance is never cre

> **Vulnerability classes:** vuln/locked-funds
>
> **Reproduction:** a faithful minimal reproduction of the vulnerable finding — the vulnerable function is reproduced **verbatim** (marked `@>`) with faithful minimal doubles; local deploy, no fork.

<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/63508-requestredemption-reverts-because-l1btcredeemerwormholes-ban.md -->

## Root cause

Every Wormhole tBTC redemption reverts because the redeemer's satoshi balance is never credited in the Bank, so Bridge.requestRedemption's bank.transferBalanceFrom reverts ("Transfer amount exceeds balance") — bridged tBTC is permanently stranded (redemption-path DoS).

```solidity
    ) internal returns (uint256 redemptionKey, uint256 tbtcAmount) {
        // This contract (as balanceOwner) approves the Bridge to spend its Bank balance.
        // The amount for Bank allowance is in satoshi units (which is what `amount` already is).
        bank.increaseBalanceAllowance(address(thresholdBridge), amount); // @> grants the Bridge an allowance but NEVER credits this contract's Bank balance (the `tbtcVault.unmint` credit is missing) — Bridge.transferBalanceFrom later reverts

        // This contract calls the Bridge. The Bridge will see `msg.sender` (this contract) as the `balanceOwner`.
```

## Why it's exploitable here

Every Wormhole tBTC redemption reverts because the redeemer's satoshi balance is never credited in the Bank, so Bridge.requestRedemption's bank.transferBalanceFrom reverts ("Transfer amount exceeds balance") — bridged tBTC is permanently stranded (redemption-path DoS).

## Attack path

```mermaid
flowchart TD
  S0["VULN step 1"]
  H["Every Wormhole tBTC redemption reverts because the redeemer's satoshi "]
  S0 --> H
```

## Marked-line walkthrough (Playground)

The EVM Playground pins each step to the exact executed source line in `0xcc0e8eedd7…`:

1. **L403** — VULN step 1: grants the Bridge an allowance but NEVER credits this contract's Bank balance (the `tbtcVault.unmint` credit is missing) — Bridge.transferBalanceFrom later reverts

## PoC

Registry (Foundry, local deploy — verbatim vulnerable source + harm-asserting test + negative control):

```bash
cd 63508-requestredemption-reverts-because-l1btcredeemerwormholes-ban_exp
forge test -vvv
```

The browser Playground replays the same synthetic opcode-for-opcode and measures the harm: **Every Wormhole tBTC redemption reverts because the redeemer's satoshi balance is never credited in the Bank, so Bridge.requestRedemption's b**. Both gates are green (registry `forge test` PASS + Playground `_verify-poc` **VERDICT: PASS**).
