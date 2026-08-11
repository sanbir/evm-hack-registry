# RipIt: A spin with prizeCount=2 makes SpinLottery's min-guarantee reserve the lone scarce high-ra

> **Vulnerability classes:** vuln/locked-funds
>
> **Reproduction:** a faithful minimal reproduction of the vulnerable finding — the vulnerable function is reproduced **verbatim** (marked `@>`) with faithful minimal doubles; local deploy, no fork.

<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/62541-h-04-dos-risk-from-pending-prize-locking-mechanism-pashov-au.md -->

## Root cause

A spin with prizeCount=2 makes SpinLottery's min-guarantee reserve the lone scarce high-rarity prize (whose weighted allocation is 0), locking the whole supply as pending so every subsequent user's spin reverts InsufficientPrizes — a temporary DoS; 1 scarce prize is marked locked to the SINK and UserB's spin actually reverts, while deleting the min-guarantee line lets UserB spin succeed.

```solidity
        uint256 pendingCount = (_prizeCount * weight) / totalWeight;

        // Ensure at least some prizes are allocated if weights allow it
        if (_prizeCount > 1 && pendingCount == 0 && weight > 0) { // @> min-guarantee reserves a scarce prize even when the weighted allocation is 0 -> locks the whole scarce supply
            pendingCount = 1;
        }
```

## Why it's exploitable here

A spin with prizeCount=2 makes SpinLottery's min-guarantee reserve the lone scarce high-rarity prize (whose weighted allocation is 0), locking the whole supply as pending so every subsequent user's spin reverts InsufficientPrizes — a temporary DoS; 1 scarce prize is marked locked to the SINK and UserB's spin actually reverts, while deleting the min-guarantee line lets UserB spin succeed.

## Attack path

```mermaid
flowchart TD
  S0["VULN step 1"]
  S1["VULN step 2"]
  H["A spin with prizeCount=2 makes SpinLottery's min-guarantee reserve the"]
  S0 --> S1
  S1 --> H
```

## Marked-line walkthrough (Playground)

The EVM Playground pins each step to the exact executed source line in `0x8ea53755a6…`:

1. **L115** — VULN step 1: min-guarantee reserves a scarce prize even when the weighted allocation is 0 -> locks the whole scarce supply
2. **L139** — VULN step 2: min-guarantee reserves a scarce prize even when the weighted allocation is 0 -> locks the whole scarce supply

## PoC

Registry (Foundry, local deploy — verbatim vulnerable source + harm-asserting test + negative control):

```bash
cd 62541-h-04-dos-risk-from-pending-prize-locking-mechanism-pashov-au_exp
forge test -vvv
```

The browser Playground replays the same synthetic opcode-for-opcode and measures the harm: **A spin with prizeCount=2 makes SpinLottery's min-guarantee reserve the lone scarce high-rarity prize (whose weighted allocation is 0), locki**. Both gates are green (registry `forge test` PASS + Playground `_verify-poc` **VERDICT: PASS**).
