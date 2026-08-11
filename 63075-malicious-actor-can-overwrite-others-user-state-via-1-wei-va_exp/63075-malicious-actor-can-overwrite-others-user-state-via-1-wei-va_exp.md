# Superform: A 1-wei SuperVault share transfer clones the sender's fulfilled-redeem state (maxWithdraw=

> **Vulnerability classes:** vuln/theft
>
> **Reproduction:** a faithful minimal reproduction of the vulnerable finding — the vulnerable function is reproduced **verbatim** (marked `@>`) with faithful minimal doubles; local deploy, no fork.

<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/63075-malicious-actor-can-overwrite-others-user-state-via-1-wei-va.md -->

## Root cause

A 1-wei SuperVault share transfer clones the sender's fulfilled-redeem state (maxWithdraw=100) onto the recipient via _update, letting the attacker double-withdraw and drain 100 STOLEN-ASSET of another user's escrowed funds to the attacker EOA (escrow drained 200->0; victim's 100 claim left unbacked).

```solidity

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE SuperVault: the ERC20 share token. `_update` is VERBATIM from the
// pre-fix audited source — it copies the sender's ENTIRE SuperVaultState onto
// the recipient on every real-user share transfer.
// ─────────────────────────────────────────────────────────────────────────────
```

## Why it's exploitable here

A 1-wei SuperVault share transfer clones the sender's fulfilled-redeem state (maxWithdraw=100) onto the recipient via _update, letting the attacker double-withdraw and drain 100 STOLEN-ASSET of another user's escrowed funds to the attacker EOA (escrow drained 200->0; victim's 100 claim left unbacked).

## Attack path

```mermaid
flowchart TD
  S0["SuperVault share token declared"]
  S1["Strategy holds redeem state"]
  S2["Wire vault to strategy and escrow"]
  S3["Transfer override clones redeem state"]
  S4["Fixed variant initializer"]
  H["A 1-wei SuperVault share transfer clones the sender's fulfilled-redeem"]
  S0 --> S1
  S1 --> S2
  S2 --> S3
  S3 --> S4
  S4 --> H
```

## Marked-line walkthrough (Playground)

The EVM Playground pins each step to the exact executed source line in `0xbd4fd5a3ce…`:

1. **L230** — SuperVault share token declared: Setup: `SuperVault` is an ERC20 share token, so every share transfer is routed through its `_update` override.
2. **L231** — Strategy holds redeem state: Setup: `strategy` records each holder's fulfilled-redeem state (like `maxWithdraw`) that the transfer bug will clone.
3. **L234** — Wire vault to strategy and escrow: Setup: `initialize` links the vault to its `strategy` and `escrow` contracts.
4. **L246** — Transfer override clones redeem state: Every share transfer runs `_update`, which wrongly copies the sender's fulfilled-redeem state onto the recipient.
5. **L264** — Fixed variant initializer: Setup: the patched variant's `initialize`, wiring strategy and escrow ahead of the corrected transfer guard.
6. **L269** — Mint shares to a holder: Setup: `mintShares` issues share tokens to a holder — a mint (`from==0`) the fix must exclude from state-cloning.
7. **L275** — Fixed guard skips mint/escrow legs: The patched check clones redeem state only for real holder-to-holder transfers, excluding zero-address and escrow legs.

## PoC

Registry (Foundry, local deploy — verbatim vulnerable source + harm-asserting test + negative control):

```bash
cd 63075-malicious-actor-can-overwrite-others-user-state-via-1-wei-va_exp
forge test -vvv
```

The browser Playground replays the same synthetic opcode-for-opcode and measures the harm: **A 1-wei SuperVault share transfer clones the sender's fulfilled-redeem state (maxWithdraw=100) onto the recipient via _update, letting the a**. Both gates are green (registry `forge test` PASS + Playground `_verify-poc` **VERDICT: PASS**).
