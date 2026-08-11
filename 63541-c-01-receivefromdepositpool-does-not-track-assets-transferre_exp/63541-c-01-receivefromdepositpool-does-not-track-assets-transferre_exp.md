# Elytra: receiveFromDepositPool reads balanceBefore and balanceAfter with no transfer between them 

> **Vulnerability classes:** vuln/locked-funds
>
> **Reproduction:** a faithful minimal reproduction of the vulnerable finding — the vulnerable function is reproduced **verbatim** (marked `@>`) with faithful minimal doubles; local deploy, no fork.

<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/63541-c-01-receivefromdepositpool-does-not-track-assets-transferre.md -->

## Root cause

receiveFromDepositPool reads balanceBefore and balanceAfter with no transfer between them so received is always 0; claimableAssets never increases, every withdrawer's claim pays 0 while 10e18 WHYPE stays permanently locked in the unstaking vault.

```solidity
        uint256 balanceBefore = IERC20(asset).balanceOf(address(this));
        // Assets should be transferred before calling this function
        uint256 balanceAfter = IERC20(asset).balanceOf(address(this));
        uint256 received = balanceAfter - balanceBefore; // @> balanceBefore and balanceAfter are read with NO transfer between them, so received is ALWAYS 0
        claimableAssets[asset] += received;
        emit AssetsReceivedFromDepositPool(asset, received);
```

## Why it's exploitable here

receiveFromDepositPool reads balanceBefore and balanceAfter with no transfer between them so received is always 0; claimableAssets never increases, every withdrawer's claim pays 0 while 10e18 WHYPE stays permanently locked in the unstaking vault.

## Attack path

```mermaid
flowchart TD
  S0["Read balance after, no transfer"]
  S1["received always computes to zero"]
  S2["Withdrawer calls claim()"]
  S3["Read vault asset balance"]
  S4["Pay is min(owed, balance)"]
  H["receiveFromDepositPool reads balanceBefore and balanceAfter with no tr"]
  S0 --> S1
  S1 --> S2
  S2 --> S3
  S3 --> S4
  S4 --> H
```

## Marked-line walkthrough (Playground)

The EVM Playground pins each step to the exact executed source line in `0x671d353a77…`:

1. **L87** — Read balance after, no transfer: Reads `balanceAfter` right after `balanceBefore`, but no token transfer happens between the two snapshots.
2. **L88** — received always computes to zero: Root cause: `received = balanceAfter - balanceBefore` with no transfer in between is always 0, so `claimableAssets` never grows.
3. **L95** — Withdrawer calls claim(): The `claim` function is the path a withdrawer uses to pull their owed assets out to `to`.
4. **L97** — Read vault asset balance: Reads the vault's current `asset` balance to cap the payout at whatever is actually on hand.
5. **L98** — Pay is min(owed, balance): `pay` is the lesser of `owed` and balance; since `owed` was never credited it resolves to 0, so the claim pays nothing.
6. **L111** — claimableAssets never increases: `claimableAssets` maps asset to owed amount — the accounting the broken `received` calc leaves permanently at zero.
7. **L116** — Restrict caller to deposit pool: Setup: guards `receiveFromDepositPool` so only the deposit pool can invoke it.

## PoC

Registry (Foundry, local deploy — verbatim vulnerable source + harm-asserting test + negative control):

```bash
cd 63541-c-01-receivefromdepositpool-does-not-track-assets-transferre_exp
forge test -vvv
```

The browser Playground replays the same synthetic opcode-for-opcode and measures the harm: **receiveFromDepositPool reads balanceBefore and balanceAfter with no transfer between them so received is always 0; claimableAssets never inc**. Both gates are green (registry `forge test` PASS + Playground `_verify-poc` **VERDICT: PASS**).
