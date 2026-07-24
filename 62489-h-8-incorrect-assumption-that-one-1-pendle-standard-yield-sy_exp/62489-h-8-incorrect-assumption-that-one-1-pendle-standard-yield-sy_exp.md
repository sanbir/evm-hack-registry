# Oracle treats SY and yield tokens as equal — AuditVault synthetic reduction

> **Vulnerability classes:** vuln/oracle/price-calculation · vuln/arithmetic/decimal-mismatch
>
> **Reproduction:** self-contained Foundry PoC with an offline synthetic contract. Full trace: [output.txt](output.txt).

<!-- non-defihacklabs -->
<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/62489-h-8-incorrect-assumption-that-one-1-pendle-standard-yield-sy.md -->
<!-- date: 2025-06 -->

**AuditVault finding:** `62489` · `H-8: Incorrect assumption that one (1) Pendle Standard Yield (SY) token is equal to one (1) Yield Token when computing the price in the oracle`

## Key info

| | |
|---|---|
| **Impact** | **HIGH** — Oracle treats SY and yield tokens as equal |
| **Protocol** | [[Notional]] Exponent |
| **Finding** | AuditVault #62489 |
| **Report** | [https://github.com/sherlock-audit/2025-06-notional-exponent-judging](https://github.com/sherlock-audit/2025-06-notional-exponent-judging) |
| **Source** | [AuditVault finding](https://github.com/Auditware/AuditVault/blob/main/findings/62489-h-8-incorrect-assumption-that-one-1-pendle-standard-yield-sy.md) |
| **Compiler** | `^0.8.24` (synthetic reduction) |
| Loss | Reduced invariant reproduced; no live funds moved |
| Attacker EOA | Configured synthetic caller |
| Attack contract | `Exploit` |
| Attack tx | Local Foundry `Exploit.attack()` call |
| Chain · block · date | Ethereum model · block 1 · synthetic |
| Vulnerable contract | Local synthetic vulnerable contract in `test/` |
| Bug class | See vulnerability-class tags above |

## TL;DR

This bug report is about an issue found in the Pendle yield strategy code. The bug was discovered by two individuals and it is caused by an incorrect assumption in the code. The code assumes that one Pendle Standard Yield (SY) token is equal to one Yield Token when calculating the price in the oracle. However, this is not always true and can result in an inflated price. This bug can have a high impact as it can lead to the protocol's solvency being affected and an increased risk of bad debt. There is currently no response or mitigation for this bug.

## Background

The upstream report is a Solidity finding. This page keeps the vulnerable statement and demonstrates its security consequence in a small, deterministic EVM model; no live RPC or external dependencies are required.

## The vulnerable code

```solidity
// The exact vulnerable pattern is retained in test/62489-h-8-incorrect-assumption-that-one-1-pendle-standard-yield-sy.sol.
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
cd evm-hack-registry/62489-h-8-incorrect-assumption-that-one-1-pendle-standard-yield-sy_exp
forge test -vvvvv
```

The test is offline and uses only the shared `forge-std` library. The corresponding Playground bundle is generated from `scripts/poc-configs/62489-h-8-incorrect-assumption-that-one-1-pendle-standard-yield-sy.mjs`.

## Sources

- [AuditVault finding](https://github.com/Auditware/AuditVault/blob/main/findings/62489-h-8-incorrect-assumption-that-one-1-pendle-standard-yield-sy.md)
- [https://github.com/sherlock-audit/2025-06-notional-exponent-judging](https://github.com/sherlock-audit/2025-06-notional-exponent-judging)
- [Synthetic test](test/62489-h-8-incorrect-assumption-that-one-1-pendle-standard-yield-sy.sol)

*Reference: https://github.com/sherlock-audit/2025-06-notional-exponent-judging*
