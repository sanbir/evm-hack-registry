# Radius Technology: Expired auth tokens are pruned from the custom group ledger but never burned from the auth

> **Vulnerability classes:** vuln/locked-funds · vuln/access-control
>
> **Reproduction:** a faithful minimal reproduction of the vulnerable finding — the vulnerable function is reproduced **verbatim** (marked `@>`) with faithful minimal doubles; local deploy, no fork.

<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/62866-expired-token-groups-not-synchronized-with-erc1155-balance-t.md -->

## Root cause

Expired auth tokens are pruned from the custom group ledger but never burned from the authoritative ERC1155 balance, so 50 phantom expired tokens remain transferable and are moved to the sink (should have been destroyed).

```solidity
        }
        // If any expired groups were removed, emit an event with the total amount of expired tokens
        if (expiredAmount > 0) {
            emit ExpiredTokensBurned(account, id, expiredAmount); // @> removes expired records and emits "burned", but NEVER burns the underlying ERC1155 balance -> phantom balance stays transferable
        }
    }
```

## Why it's exploitable here

Expired auth tokens are pruned from the custom group ledger but never burned from the authoritative ERC1155 balance, so 50 phantom expired tokens remain transferable and are moved to the sink (should have been destroyed).

## Attack path

```mermaid
flowchart TD
  S0["ERC1155 approval setter"]
  S1["Guard transfer against balance"]
  S2["Real burn function exists"]
  S3["Load account's token groups"]
  S4["Init expired-amount accumulator"]
  H["Expired auth tokens are pruned from the custom group ledger but never "]
  S0 --> S1
  S1 --> S2
  S2 --> S3
  S3 --> S4
  S4 --> H
```

## Marked-line walkthrough (Playground)

The EVM Playground pins each step to the exact executed source line in `0x8ea53755a6…`:

1. **L57** — ERC1155 approval setter: Setup: standard `setApprovalForAll` on the ERC1155 auth-token contract.
2. **L73** — Guard transfer against balance: Checks the sender holds enough ERC1155 balance — the authoritative ledger that the expiry logic fails to update.
3. **L91** — Real burn function exists: `_burn` actually reduces ERC1155 balance — the call the expiry path should make but never does.
4. **L125** — Load account's token groups: Reads the custom per-account `_group` ledger that tracks token batches and their expiry timestamps.
5. **L139** — Init expired-amount accumulator: Starts `expiredAmount`, the counter summing how many tokens across the groups have expired.
6. **L156** — Some tokens have expired: Branch taken when `expiredAmount > 0` after expired entries are pruned from the group ledger.
7. **L157** — Emits burn event without burning: Root cause: only emits `ExpiredTokensBurned` — it prunes the group ledger but never calls `_burn`, so phantom expired tokens stay transferable.

## PoC

Registry (Foundry, local deploy — verbatim vulnerable source + harm-asserting test + negative control):

```bash
cd 62866-expired-token-groups-not-synchronized-with-erc1155-balance-t_exp
forge test -vvv
```

The browser Playground replays the same synthetic opcode-for-opcode and measures the harm: **Expired auth tokens are pruned from the custom group ledger but never burned from the authoritative ERC1155 balance, so 50 phantom expired t**. Both gates are green (registry `forge test` PASS + Playground `_verify-poc` **VERDICT: PASS**).
