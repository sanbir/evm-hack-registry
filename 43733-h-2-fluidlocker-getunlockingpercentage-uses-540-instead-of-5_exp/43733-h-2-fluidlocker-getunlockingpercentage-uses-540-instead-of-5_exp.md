# 540 seconds is used instead of 540 days — AuditVault synthetic reduction

> **Vulnerability classes:** vuln/arithmetic/underflow · vuln/input-validation/boundary
>
> **Reproduction:** self-contained Foundry PoC with an offline synthetic contract. Full trace: [output.txt](output.txt).

<!-- non-defihacklabs -->
<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/43733-h-2-fluidlocker-getunlockingpercentage-uses-540-instead-of-5.md -->
<!-- date: 2025-03 -->

**AuditVault finding:** `43733` · `H-2: `FluidLocker::_getUnlockingPercentage()` uses 540 instead of `540 days` leading to stuck funds as the unlocking percentage will be bigger than `100%` and underflow`

## Key info

| | |
|---|---|
| **Impact** | **HIGH** — 540 seconds is used instead of 540 days |
| **Protocol** | [[Superfluid]] Locking Contract |
| **Finding** | AuditVault #43733 |
| **Report** | [https://github.com/sherlock-audit/2024-11-superfluid-locking-contract-judging](https://github.com/sherlock-audit/2024-11-superfluid-locking-contract-judging) |
| **Source** | [AuditVault finding](https://github.com/Auditware/AuditVault/blob/main/findings/43733-h-2-fluidlocker-getunlockingpercentage-uses-540-instead-of-5.md) |
| **Compiler** | `^0.8.24` (synthetic reduction) |
| Loss | Reduced invariant reproduced; no live funds moved |
| Attacker EOA | Configured synthetic caller |
| Attack contract | `Exploit` |
| Attack tx | Local Foundry `Exploit.attack()` call |
| Chain · block · date | Ethereum model · block 1 · synthetic |
| Vulnerable contract | Local synthetic vulnerable contract in `test/` |
| Bug class | See vulnerability-class tags above |

## TL;DR

The report discusses a bug found in the Superfluid locking contract, where the function _getUnlockingPercentage() incorrectly uses the number 540 instead of 540 days, leading to a large error and potential underflow. This can result in users being unable to unlock their funds or being forced to take a penalty. The root cause is identified as using 540 instead of 540 days in line 388 of the contract. The impact is that users may have their funds stuck or be forced to take a penalty. A fix for this issue has been included in a pull request by the protocol team.

## Background

The upstream report is a Solidity finding. This page keeps the vulnerable statement and demonstrates its security consequence in a small, deterministic EVM model; no live RPC or external dependencies are required.

## The vulnerable code

```solidity
// The exact vulnerable pattern is retained in test/43733-h-2-fluidlocker-getunlockingpercentage-uses-540-instead-of-5.sol.
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
cd evm-hack-registry/43733-h-2-fluidlocker-getunlockingpercentage-uses-540-instead-of-5_exp
forge test -vvvvv
```

The test is offline and uses only the shared `forge-std` library. The corresponding Playground bundle is generated from `scripts/poc-configs/43733-h-2-fluidlocker-getunlockingpercentage-uses-540-instead-of-5.mjs`.

## Sources

- [AuditVault finding](https://github.com/Auditware/AuditVault/blob/main/findings/43733-h-2-fluidlocker-getunlockingpercentage-uses-540-instead-of-5.md)
- [https://github.com/sherlock-audit/2024-11-superfluid-locking-contract-judging](https://github.com/sherlock-audit/2024-11-superfluid-locking-contract-judging)
- [Synthetic test](test/43733-h-2-fluidlocker-getunlockingpercentage-uses-540-instead-of-5.sol)

*Reference: https://github.com/sherlock-audit/2024-11-superfluid-locking-contract-judging*
