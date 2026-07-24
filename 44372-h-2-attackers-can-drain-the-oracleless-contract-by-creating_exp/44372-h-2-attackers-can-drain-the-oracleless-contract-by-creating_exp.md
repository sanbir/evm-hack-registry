# OracleLess executes attacker-controlled target — AuditVault synthetic reduction

> **Vulnerability classes:** vuln/access-control/missing-auth · vuln/dependency/unsafe-external-call
>
> **Reproduction:** self-contained Foundry PoC with an offline synthetic contract. Full trace: [output.txt](output.txt).

<!-- non-defihacklabs -->
<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/44372-h-2-attackers-can-drain-the-oracleless-contract-by-creating.md -->
<!-- date: 2024-11 -->

**AuditVault finding:** `44372` · `H-2: Attackers can drain the `OracleLess` contract by creating an order with a `malicious tokenIn` and executing it with a `malicious target`.`

## Key info

| | |
|---|---|
| **Impact** | **HIGH** — OracleLess executes attacker-controlled target |
| **Protocol** | [[Oku'S New Order Types Contract Contest]] |
| **Finding** | AuditVault #44372 |
| **Report** | [https://github.com/sherlock-audit/2024-11-oku-judging](https://github.com/sherlock-audit/2024-11-oku-judging) |
| **Source** | [AuditVault finding](https://github.com/Auditware/AuditVault/blob/main/findings/44372-h-2-attackers-can-drain-the-oracleless-contract-by-creating.md) |
| **Compiler** | `^0.8.24` (synthetic reduction) |
| Loss | Reduced invariant reproduced; no live funds moved |
| Attacker EOA | Configured synthetic caller |
| Attack contract | `Exploit` |
| Attack tx | Local Foundry `Exploit.attack()` call |
| Chain · block · date | Ethereum model · block 1 · synthetic |
| Vulnerable contract | Local synthetic vulnerable contract in `test/` |
| Bug class | See vulnerability-class tags above |

## TL;DR

The `OracleLess` contract has a vulnerability that allows attackers to drain all `USDT` from the contract. This is caused by the `createOrder()` function not verifying if the `tokenIn` is a legitimate ERC20 token and the `fillOrder()` function not checking if the `target` and `txData` are valid. This allows attackers to create an order with a malicious token and execute it with a malicious `target` and `txData`, resulting in all `USDT` being transferred to the attacker. A recommended solution is to implement a whitelist mechanism for `token`, `target`, and `txData` to prevent this vulnerability.

## Background

The upstream report is a Solidity finding. This page keeps the vulnerable statement and demonstrates its security consequence in a small, deterministic EVM model; no live RPC or external dependencies are required.

## The vulnerable code

```solidity
// The exact vulnerable pattern is retained in test/44372-h-2-attackers-can-drain-the-oracleless-contract-by-creating.sol.
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
cd evm-hack-registry/44372-h-2-attackers-can-drain-the-oracleless-contract-by-creating_exp
forge test -vvvvv
```

The test is offline and uses only the shared `forge-std` library. The corresponding Playground bundle is generated from `scripts/poc-configs/44372-h-2-attackers-can-drain-the-oracleless-contract-by-creating.mjs`.

## Sources

- [AuditVault finding](https://github.com/Auditware/AuditVault/blob/main/findings/44372-h-2-attackers-can-drain-the-oracleless-contract-by-creating.md)
- [https://github.com/sherlock-audit/2024-11-oku-judging](https://github.com/sherlock-audit/2024-11-oku-judging)
- [Synthetic test](test/44372-h-2-attackers-can-drain-the-oracleless-contract-by-creating.sol)

*Reference: https://github.com/sherlock-audit/2024-11-oku-judging*
