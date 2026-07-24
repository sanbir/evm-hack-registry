# Reduced plugin price leaves excess payment trapped — AuditVault synthetic reduction

> **Vulnerability classes:** vuln/logic/fee-calculation · vuln/input-validation/missing
>
> **Reproduction:** self-contained Foundry PoC with an offline synthetic contract. Full trace: [output.txt](output.txt).

<!-- non-defihacklabs -->
<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/53453-h-01-excess-payment-when-plugin-owner-reduces-price-shieldif.md -->
<!-- date: 2025-01 -->

**AuditVault finding:** `53453` · `[H-01] Excess Payment When Plugin Owner Reduces Price`

## Key info

| | |
|---|---|
| **Impact** | **HIGH** — Reduced plugin price leaves excess payment trapped |
| **Protocol** | Bullasv2 |
| **Finding** | AuditVault #53453 |
| **Report** | [https://github.com/shieldify-security/audits-portfolio-md/blob/main/BullasV2-Security-Review.md](https://github.com/shieldify-security/audits-portfolio-md/blob/main/BullasV2-Security-Review.md) |
| **Source** | [AuditVault finding](https://github.com/Auditware/AuditVault/blob/main/findings/53453-h-01-excess-payment-when-plugin-owner-reduces-price-shieldif.md) |
| **Compiler** | `^0.8.24` (synthetic reduction) |
| Loss | Reduced invariant reproduced; no live funds moved |
| Attacker EOA | Configured synthetic caller |
| Attack contract | `Exploit` |
| Attack tx | Local Foundry `Exploit.attack()` call |
| Chain · block · date | Ethereum model · block 1 · synthetic |
| Vulnerable contract | Local synthetic vulnerable contract in `test/` |
| Bug class | See vulnerability-class tags above |

## TL;DR

The report discusses a bug in the `Multicall` contract where the `click()` function does not properly check the `msg.value` sent by users. This can lead to a vulnerability where users may send more ETH than necessary, which gets locked in the contract. The bug is located in the `Multicall.sol` file and can be exploited if the plugin owner changes the `entryFee` while a user's transaction is pending. The team has fixed the issue and recommends checking the relationship between `msg.value` and `price` to prevent this bug from occurring.

## Background

The upstream report is a Solidity finding. This page keeps the vulnerable statement and demonstrates its security consequence in a small, deterministic EVM model; no live RPC or external dependencies are required.

## The vulnerable code

```solidity
// The exact vulnerable pattern is retained in test/53453-h-01-excess-payment-when-plugin-owner-reduces-price-shieldif.sol.
// @> see the marked statement in the synthetic reduction
```

## Root cause

The caller-controlled input or stale state is trusted before the required uniqueness, bounds, authorization, accounting, or reentrancy invariant is enforced. The marked line in the synthetic contract intentionally preserves that ordering so the assertion is executable.

## Preconditions

- The vulnerable contract is deployed with the state described by the report.
- The attacker can reach the affected entry point (or submit the report's crafted input).

## Attack walkthrough

1. `Exploit.run()` initializes the minimal state from the report.
2. The marked vulnerable operation executes without its required check.
3. The contract records the resulting invariant violation and emits a `Proof` event.
4. The test asserts the harm; the passing trace is recorded at [output.txt:4](output.txt).

## Diagrams

```mermaid
flowchart TD
    A[Attacker supplies crafted input] --> B[Vulnerable operation]
    B --> C{Missing invariant check}
    C --> D[Security impact demonstrated]
```

```mermaid
sequenceDiagram
    participant A as Attacker
    participant V as Vulnerable contract
    participant S as State
    A->>V: invoke affected entry point
    V->>S: apply unchecked update
    S-->>A: harm is observable
```

## Remediation

Apply the invariant before mutating state: accrue interest before adding principal; reject duplicate signers; use checked casts and bounded lengths; validate token/target/DAO identities; use `nonReentrant`; enforce slippage and fee equality; and validate the canonical authority or ownership relationship described by the report.

## How to reproduce

```bash
cd evm-hack-registry/53453-h-01-excess-payment-when-plugin-owner-reduces-price-shieldif_exp
forge test -vvvvv
```

The test is offline and uses only the shared `forge-std` library. The corresponding Playground bundle is generated from `scripts/poc-configs/53453-h-01-excess-payment-when-plugin-owner-reduces-price-shieldif.mjs`.

## Sources

- [AuditVault finding](https://github.com/Auditware/AuditVault/blob/main/findings/53453-h-01-excess-payment-when-plugin-owner-reduces-price-shieldif.md)
- [https://github.com/shieldify-security/audits-portfolio-md/blob/main/BullasV2-Security-Review.md](https://github.com/shieldify-security/audits-portfolio-md/blob/main/BullasV2-Security-Review.md)
- [Synthetic test](test/53453-h-01-excess-payment-when-plugin-owner-reduces-price-shieldif.sol)

*Reference: https://github.com/shieldify-security/audits-portfolio-md/blob/main/BullasV2-Security-Review.md*
