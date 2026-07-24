# Vesting claim updates index after an external call — AuditVault synthetic reduction

> **Vulnerability classes:** vuln/reentrancy/single-function · vuln/logic/state-update
>
> **Reproduction:** self-contained Foundry PoC with an offline synthetic contract. Full trace: [output.txt](output.txt).

<!-- non-defihacklabs -->
<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/31192-h-3-reentrancy-in-vestingsolclaim-will-allow-users-to-drain.md -->
<!-- date: 2023-10 -->

**AuditVault finding:** `31192` · `H-3: Reentrancy in Vesting.sol:claim() will allow users to drain the contract due to executing .call() on user's address before setting s.index = uint128(i)`

## Key info

| | |
|---|---|
| **Impact** | **HIGH** — Vesting claim updates index after an external call |
| **Protocol** | [[Zap Protocol]] |
| **Finding** | AuditVault #31192 |
| **Report** | [https://github.com/sherlock-audit/2024-03-zap-protocol-judging](https://github.com/sherlock-audit/2024-03-zap-protocol-judging) |
| **Source** | [AuditVault finding](https://github.com/Auditware/AuditVault/blob/main/findings/31192-h-3-reentrancy-in-vestingsolclaim-will-allow-users-to-drain.md) |
| **Compiler** | `^0.8.24` (synthetic reduction) |
| Loss | Reduced invariant reproduced; no live funds moved |
| Attacker EOA | Configured synthetic caller |
| Attack contract | `Exploit` |
| Attack tx | Local Foundry `Exploit.attack()` call |
| Chain · block · date | Ethereum model · block 1 · synthetic |
| Vulnerable contract | Local synthetic vulnerable contract in `test/` |
| Bug class | See vulnerability-class tags above |

## TL;DR

Issue H-3 is a vulnerability in the Vesting.sol contract that allows users to drain the contract by exploiting the claim() function. This is due to the contract executing .call() on the user's address before setting s.index = uint128(i). The vulnerability was found by multiple users and has been escalated for review. It is recommended to use a reentrancy guard to prevent this issue. Various discussions and escalations have taken place regarding the severity and validity of duplicate reports. The issue has been resolved by moving the updates above the transfers and adding a reentrancy guard.

## Background

The upstream report is a Solidity finding. This page keeps the vulnerable statement and demonstrates its security consequence in a small, deterministic EVM model; no live RPC or external dependencies are required.

## The vulnerable code

```solidity
// The exact vulnerable pattern is retained in test/31192-h-3-reentrancy-in-vestingsolclaim-will-allow-users-to-drain.sol.
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
cd evm-hack-registry/31192-h-3-reentrancy-in-vestingsolclaim-will-allow-users-to-drain_exp
forge test -vvvvv
```

The test is offline and uses only the shared `forge-std` library. The corresponding Playground bundle is generated from `scripts/poc-configs/31192-h-3-reentrancy-in-vestingsolclaim-will-allow-users-to-drain.mjs`.

## Sources

- [AuditVault finding](https://github.com/Auditware/AuditVault/blob/main/findings/31192-h-3-reentrancy-in-vestingsolclaim-will-allow-users-to-drain.md)
- [https://github.com/sherlock-audit/2024-03-zap-protocol-judging](https://github.com/sherlock-audit/2024-03-zap-protocol-judging)
- [Synthetic test](test/31192-h-3-reentrancy-in-vestingsolclaim-will-allow-users-to-drain.sol)

*Reference: https://github.com/sherlock-audit/2024-03-zap-protocol-judging*
