# Superform: A depositor who sets receiver != controller can never redeem: shares mint to the receiver 

> **Vulnerability classes:** vuln/locked-funds · vuln/unfair-mint
>
> **Reproduction:** a faithful minimal reproduction of the vulnerable finding — the vulnerable function is reproduced **verbatim** (marked `@>`) with faithful minimal doubles; local deploy, no fork.

<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/63077-controller-and-receiver-cannot-redeem-shares-after-depositin.md -->

## Root cause

A depositor who sets receiver != controller can never redeem: shares mint to the receiver while the redeem cost-basis state is recorded under the controller, so receiver-redeem reverts INSUFFICIENT_SHARES (empty state) and controller-redeem reverts (no shares) — 100 USDC is permanently locked in the vault.

```solidity

        // ── VERBATIM audited call-site: cost-basis state credited to the
        //    controller (msg.sender), shares minted to `receiver`. ──────────────
        strategy.handleOperation(msg.sender, receiver, assets, shares, ISuperVaultStrategy.Operation.Deposit); // @> state keyed to controller(msg.sender), not the share receiver
        _mint(receiver, shares);
    }
```

## Why it's exploitable here

A depositor who sets receiver != controller can never redeem: shares mint to the receiver while the redeem cost-basis state is recorded under the controller, so receiver-redeem reverts INSUFFICIENT_SHARES (empty state) and controller-redeem reverts (no shares) — 100 USDC is permanently locked in the vault.

## Attack path

```mermaid
flowchart TD
  S0["VULN step 1"]
  H["A depositor who sets receiver != controller can never redeem: shares m"]
  S0 --> H
```

## Marked-line walkthrough (Playground)

The EVM Playground pins each step to the exact executed source line in `0xce01759b82…`:

1. **L225** — VULN step 1: state keyed to controller(msg.sender), not the share receiver

## PoC

Registry (Foundry, local deploy — verbatim vulnerable source + harm-asserting test + negative control):

```bash
cd 63077-controller-and-receiver-cannot-redeem-shares-after-depositin_exp
forge test -vvv
```

The browser Playground replays the same synthetic opcode-for-opcode and measures the harm: **A depositor who sets receiver != controller can never redeem: shares mint to the receiver while the redeem cost-basis state is recorded unde**. Both gates are green (registry `forge test` PASS + Playground `_verify-poc` **VERDICT: PASS**).
