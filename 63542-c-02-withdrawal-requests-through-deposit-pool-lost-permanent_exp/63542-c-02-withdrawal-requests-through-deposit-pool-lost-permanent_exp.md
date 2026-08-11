# Elytra: A user's elyAsset is burned on requestWithdrawal

> **Vulnerability classes:** vuln/locked-funds
>
> **Reproduction:** a faithful minimal reproduction of the vulnerable finding — the vulnerable function is reproduced **verbatim** (marked `@>`) with faithful minimal doubles; local deploy, no fork.

<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/63542-c-02-withdrawal-requests-through-deposit-pool-lost-permanent.md -->

## Root cause

A user's elyAsset is burned on requestWithdrawal, but the vault records the deposit pool (msg.sender) as the request owner, so the user's completeWithdrawal() reverts forever and 6e18 underlying HYPE is permanently locked in the vault.

```solidity

        // ─── VERBATIM vulnerable assignment from the finding ───
        withdrawalRequests[requestId] = WithdrawalRequest({
            user: msg.sender, // @> records the CALLER (deposit pool), not the real user -> user can never complete
            asset: asset,
            elyAssetAmount: elyAssetAmount,
```

## Why it's exploitable here

A user's elyAsset is burned on requestWithdrawal, but the vault records the deposit pool (msg.sender) as the request owner, so the user's completeWithdrawal() reverts forever and 6e18 underlying HYPE is permanently locked in the vault.

## Attack path

```mermaid
flowchart TD
  S0["Deposit pool requests withdrawal"]
  S1["Compute underlying owed"]
  S2["Records msg.sender as owner"]
  S3["Stamp request time"]
  S4["User calls completeWithdrawal"]
  H["A user's elyAsset is burned on requestWithdrawal, but the vault record"]
  S0 --> S1
  S1 --> S2
  S2 --> S3
  S3 --> S4
  S4 --> H
```

## Marked-line walkthrough (Playground)

The EVM Playground pins each step to the exact executed source line in `0xbd4fd5a3ce…`:

1. **L152** — Deposit pool requests withdrawal: Entry: the deposit pool calls `requestWithdrawal` on the user's behalf, forwarding the elyAsset amount to burn.
2. **L157** — Compute underlying owed: Setup: `assetAmount` records the underlying HYPE the burned elyAsset entitles the withdrawer to.
3. **L163** — Records msg.sender as owner: Root cause: stores `user: msg.sender` — the deposit pool, not the real user — as the request owner, orphaning the withdrawal.
4. **L167** — Stamp request time: Setup: records `block.timestamp` on the withdrawal request struct.
5. **L173** — User calls completeWithdrawal: The real user later calls `completeWithdrawal` to redeem the underlying for their already-burned shares.
6. **L175** — Owner check reverts for user: `require(msg.sender == request.user)` fails: the stored owner is the pool, so the user can never complete and the HYPE locks.
7. **L187** — Deposit pool contract: Setup: `ElytraDepositPoolV1` is the intermediary whose address wrongly became the request owner.

## PoC

Registry (Foundry, local deploy — verbatim vulnerable source + harm-asserting test + negative control):

```bash
cd 63542-c-02-withdrawal-requests-through-deposit-pool-lost-permanent_exp
forge test -vvv
```

The browser Playground replays the same synthetic opcode-for-opcode and measures the harm: **A user's elyAsset is burned on requestWithdrawal, but the vault records the deposit pool (msg.sender) as the request owner, so the user's co**. Both gates are green (registry `forge test` PASS + Playground `_verify-poc` **VERDICT: PASS**).
