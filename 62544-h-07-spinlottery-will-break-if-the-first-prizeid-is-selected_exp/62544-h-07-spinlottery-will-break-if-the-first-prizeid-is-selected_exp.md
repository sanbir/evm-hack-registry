# RipIt: When the first prizeId is selected

> **Vulnerability classes:** vuln/locked-funds
>
> **Reproduction:** a faithful minimal reproduction of the vulnerable finding — the vulnerable function is reproduced **verbatim** (marked `@>`) with faithful minimal doubles; local deploy, no fork.

<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/62544-h-07-spinlottery-will-break-if-the-first-prizeid-is-selected.md -->

## Root cause

When the first prizeId is selected, _claimPrize does both firstPrizeId++ and nextPrizeId--, collapsing a 2-prize window to 0 after one claim; the moved survivor and its escrowed NFT are permanently stranded (next spin reverts NoPrizesAvailable), vs the fixed variant which claims both prizes.

```solidity
        }

        // If we've removed the first prize, increment firstPrizeId
        if (prizeId == pool.firstPrizeId) {
            pool.firstPrizeId++; // @> BUG: with nextPrizeId-- below, the window shrinks by 2 not 1; the moved survivor at the freed slot falls below firstPrizeId and is stranded forever
        }
```

## Why it's exploitable here

When the first prizeId is selected, _claimPrize does both firstPrizeId++ and nextPrizeId--, collapsing a 2-prize window to 0 after one claim; the moved survivor and its escrowed NFT are permanently stranded (next spin reverts NoPrizesAvailable), vs the fixed variant which claims both prizes.

## Attack path

```mermaid
flowchart TD
  S0["Decode a packed prize slot"]
  S1["Read the prize window pointers"]
  S2["Count claimable prizes"]
  S3["Enter the claim routine"]
  S4["Selected prize isn't the tail"]
  H["When the first prizeId is selected, _claimPrize does both firstPrizeId"]
  S0 --> S1
  S1 --> S2
  S2 --> S3
  S3 --> S4
  S4 --> H
```

## Marked-line walkthrough (Playground)

The EVM Playground pins each step to the exact executed source line in `0x671d353a77…`:

1. **L80** — Decode a packed prize slot: Helper `unpackPrize` decodes a packed slot into its NFT address, `tokenId`, and rarity — the accessor the claim path relies on.
2. **L97** — Read the prize window pointers: `getPointers` exposes a rarity's `first` and `next` pointers — the two indices whose gap defines how many prizes remain claimable.
3. **L106** — Count claimable prizes: `claimableCount` reports how many prizes sit between the first and next pointers in a rarity's window.
4. **L122** — Enter the claim routine: `_claimPrize` selects a prize by random value and advances the window pointers to consume it.
5. **L136** — Selected prize isn't the tail: Branch taken when the chosen `prizeId` is not the last slot, moving the tail survivor into the freed position.
6. **L145** — First-slot claim shrinks window twice: Root-cause bug: when `prizeId == firstPrizeId` the code both increments `firstPrizeId` and decrements `nextPrizeId`, collapsing a 2-prize window to 0.
7. **L153** — Unpack the won NFT: Unpacks the selected slot's packed value into the NFT address and `tokenId` to hand to the winner.

## PoC

Registry (Foundry, local deploy — verbatim vulnerable source + harm-asserting test + negative control):

```bash
cd 62544-h-07-spinlottery-will-break-if-the-first-prizeid-is-selected_exp
forge test -vvv
```

The browser Playground replays the same synthetic opcode-for-opcode and measures the harm: **When the first prizeId is selected, _claimPrize does both firstPrizeId++ and nextPrizeId--, collapsing a 2-prize window to 0 after one claim**. Both gates are green (registry `forge test` PASS + Playground `_verify-poc` **VERDICT: PASS**).
