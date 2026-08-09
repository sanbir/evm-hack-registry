# Super DCA: Cashback elapsed-time not clamped to campaign start

> **Vulnerability classes:** vuln/theft · vuln/reward-accounting
>
> **Reproduction:** a faithful minimal reproduction of the vulnerable finding — the vulnerable function is reproduced **verbatim** (marked `@>`) with faithful minimal doubles; local deploy, no fork.

<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/63419-h-1-users-with-pre-campaign-trades-will-drain-cashback-funds.md -->

## Root cause

timeElapsed = currentTime - trade.startTime is not clamped to the campaign's start, so a trade opened before the campaign claims retroactive cashback for pre-campaign epochs, draining the pool (50 of 60 USDC) that a correctly-clamped contract would owe as 0.

```solidity
    uint256 currentTime = block.timestamp;
    if (currentTime <= trade.startTime) return (0, 0);

    uint256 timeElapsed = currentTime - trade.startTime; // @> no clamp to cashbackClaim.startTime: counts pre-campaign time as completed epochs
    completedEpochs = timeElapsed / cashbackClaim.duration;
    incompleteEpochTime = timeElapsed % cashbackClaim.duration;
```

## Why it's exploitable here

A trade created 5.5 epochs BEFORE the campaign start claims retroactive cashback for 5 completed epochs (50 USDC, 6-dp) — all predating the campaign — draining the USDC cashback pool from 60 to 10 USDC; a correctly-clamped contract owes 0, so all 50 USDC is theft that the attacker EOA receives.

## Attack path

```mermaid
flowchart TD
  S0["_isTradeValid ignores campaign start"]
  S1["Pre-campaign time counted as completed epochs"]
  H["A trade created 5.5 epochs BEFORE the campaign start claims retroactiv"]
  S0 --> S1
  S1 --> H
```

## Marked-line walkthrough (Playground)

The EVM Playground pins each step to the exact executed source line in `0xce01759b82…`:

1. **L332** — _isTradeValid ignores campaign start: Validity never checks trade.startTime >= cashbackClaim.startTime, so a pre-campaign trade qualifies.
2. **L347** — Pre-campaign time counted as completed epochs: timeElapsed spans before the campaign start, so 5 pre-campaign epochs are paid — 50 USDC drained to the attacker.

## PoC

Registry (Foundry, local deploy — verbatim vulnerable source + harm-asserting test + negative control):

```bash
cd 63419-h-1-users-with-pre-campaign-trades-will-drain-cashback-funds_exp
forge test -vvv
```

The browser Playground replays the same synthetic opcode-for-opcode and measures the harm: **A trade created 5.5 epochs BEFORE the campaign start claims retroactive cashback for 5 completed epochs (50 USDC, 6-dp) — all predating the campaign — draining the USDC cashback pool from 60 to 10 USDC; a correctly-clamped contract owes 0, so all 50 USDC is theft that the attacker EOA receives.**. Both gates are green (registry `forge test` PASS + Playground `_verify-poc` **VERDICT: PASS**).
