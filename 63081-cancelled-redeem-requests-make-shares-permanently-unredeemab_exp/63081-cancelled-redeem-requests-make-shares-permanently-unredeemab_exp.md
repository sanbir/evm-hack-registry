# Superform: A user who cancels a pending redeem has their per-controller accumulatorShares/accumulator

> **Vulnerability classes:** vuln/locked-funds
>
> **Reproduction:** a faithful minimal reproduction of the vulnerable finding — the vulnerable function is reproduced **verbatim** (marked `@>`) with faithful minimal doubles; local deploy, no fork.

<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/63081-cancelled-redeem-requests-make-shares-permanently-unredeemab.md -->

## Root cause

A user who cancels a pending redeem has their per-controller accumulatorShares/accumulatorCostBasis wiped by `delete superVaultState[controller]`, so every subsequent fulfillRedeem reverts INSUFFICIENT_SHARES() and their 100 shares' full asset backing (100e18) is frozen in the strategy forever.

```solidity
        uint256 pendingShares = state.pendingRedeemRequest;
        if (pendingShares == 0) revert REQUEST_NOT_FOUND();
        delete superVaultState[controller]; // @> BUG: wipes accumulatorShares/accumulatorCostBasis, not just the pending request
        emit RedeemRequestCanceled(controller, pendingShares);
    }

```

## Why it's exploitable here

A user who cancels a pending redeem has their per-controller accumulatorShares/accumulatorCostBasis wiped by `delete superVaultState[controller]`, so every subsequent fulfillRedeem reverts INSUFFICIENT_SHARES() and their 100 shares' full asset backing (100e18) is frozen in the strategy forever.

## Attack path

```mermaid
flowchart TD
  S0["Per-controller state struct field"]
  S1["Accumulate shares on deposit"]
  S2["Request a redeem"]
  S3["Record pending redeem amount"]
  S4["Cancel guards zero controller"]
  H["A user who cancels a pending redeem has their per-controller accumulat"]
  S0 --> S1
  S1 --> S2
  S2 --> S3
  S3 --> S4
  S4 --> H
```

## Marked-line walkthrough (Playground)

The EVM Playground pins each step to the exact executed source line in `0x671d353a77…`:

1. **L90** — Per-controller state struct field: Setup: `averageWithdrawPrice` is one field of the per-controller state that cancel will wipe.
2. **L111** — Accumulate shares on deposit: Deposit grows `accumulatorShares`, the cost-basis that backs the controller's future redeem.
3. **L118** — Request a redeem: `requestRedeem` marks how many shares the controller intends to redeem.
4. **L129** — Record pending redeem amount: Stores the request into `pendingRedeemRequest` for later fulfillment.
5. **L137** — Cancel guards zero controller: Cancel-redeem rejects a zero `controller` address before proceeding.
6. **L142** — Cancel wipes all controller state: Root cause: cancel runs `delete superVaultState[controller]`, wiping accumulatorShares/costBasis — all backing, not just the pending request.
7. **L147** — Fulfill now reverts forever: `fulfillRedeem` reverts `INSUFFICIENT_SHARES` after cancel, freezing the user's 100 shares' 100e18 backing.

## PoC

Registry (Foundry, local deploy — verbatim vulnerable source + harm-asserting test + negative control):

```bash
cd 63081-cancelled-redeem-requests-make-shares-permanently-unredeemab_exp
forge test -vvv
```

The browser Playground replays the same synthetic opcode-for-opcode and measures the harm: **A user who cancels a pending redeem has their per-controller accumulatorShares/accumulatorCostBasis wiped by `delete superVaultState[control**. Both gates are green (registry `forge test` PASS + Playground `_verify-poc` **VERDICT: PASS**).
