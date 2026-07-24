# Hardcoded useEth flag traps pool withdrawals — AuditVault synthetic reduction

> **Vulnerability classes:** vuln/logic/incorrect-state-transition · vuln/input-validation/missing
>
> **Reproduction:** self-contained Foundry PoC with an offline synthetic contract. Full trace: [output.txt](output.txt).

<!-- non-defihacklabs -->
<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/62490-h-9-hardcoded-useeth-true-in-remove-liquidity-one-coin-or-re.md -->
<!-- date: 2025-06 -->

**AuditVault finding:** `62490` · `H-9: Hardcoded `useEth = true` in `remove_liquidity_one_coin` or `remove_liquidity` lead to stuck fund`

## Key info

| | |
|---|---|
| **Impact** | **HIGH** — Hardcoded useEth flag traps pool withdrawals |
| **Protocol** | [[Notional]] Exponent |
| **Finding** | AuditVault #62490 |
| **Report** | [https://github.com/sherlock-audit/2025-06-notional-exponent-judging](https://github.com/sherlock-audit/2025-06-notional-exponent-judging) |
| **Source** | [AuditVault finding](https://github.com/Auditware/AuditVault/blob/main/findings/62490-h-9-hardcoded-useeth-true-in-remove-liquidity-one-coin-or-re.md) |
| **Compiler** | `^0.8.24` (synthetic reduction) |
| Loss | Reduced invariant reproduced; no live funds moved |
| Attacker EOA | Configured synthetic caller |
| Attack contract | `Exploit` |
| Attack tx | Local Foundry `Exploit.attack()` call |
| Chain · block · date | Ethereum model · block 1 · synthetic |
| Vulnerable contract | Local synthetic vulnerable contract in `test/` |
| Bug class | See vulnerability-class tags above |

## TL;DR

This bug report is about a problem found by two users, elolpuer and xiaoming90, in a code repository on GitHub. The bug affects a feature called Curve V2 pool, which is used for trading cryptocurrency. The bug can cause a loss of assets for users. The root cause of the bug is a mistake in the code, which causes the wrong type of cryptocurrency to be used when exiting the pool. This leads to the loss of assets for users. The bug can be fixed by updating the code to use the correct type of cryptocurrency when exiting the pool.

## Background

The upstream report is a Solidity finding. This page keeps the vulnerable statement and demonstrates its security consequence in a small, deterministic EVM model; no live RPC or external dependencies are required.

## The vulnerable code

```solidity
// The exact vulnerable pattern is retained in test/62490-h-9-hardcoded-useeth-true-in-remove-liquidity-one-coin-or-re.sol.
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
cd evm-hack-registry/62490-h-9-hardcoded-useeth-true-in-remove-liquidity-one-coin-or-re_exp
forge test -vvvvv
```

The test is offline and uses only the shared `forge-std` library. The corresponding Playground bundle is generated from `scripts/poc-configs/62490-h-9-hardcoded-useeth-true-in-remove-liquidity-one-coin-or-re.mjs`.

## Sources

- [AuditVault finding](https://github.com/Auditware/AuditVault/blob/main/findings/62490-h-9-hardcoded-useeth-true-in-remove-liquidity-one-coin-or-re.md)
- [https://github.com/sherlock-audit/2025-06-notional-exponent-judging](https://github.com/sherlock-audit/2025-06-notional-exponent-judging)
- [Synthetic test](test/62490-h-9-hardcoded-useeth-true-in-remove-liquidity-one-coin-or-re.sol)

*Reference: https://github.com/sherlock-audit/2025-06-notional-exponent-judging*
