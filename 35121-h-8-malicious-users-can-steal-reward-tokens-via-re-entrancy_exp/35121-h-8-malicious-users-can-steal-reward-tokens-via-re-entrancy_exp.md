# Reward claim reentrancy pays twice — AuditVault synthetic reduction

> **Vulnerability classes:** vuln/reentrancy/single-function · vuln/logic/state-update
>
> **Reproduction:** self-contained Foundry PoC with an offline synthetic contract. Full trace: [output.txt](output.txt).

<!-- non-defihacklabs -->
<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/35121-h-8-malicious-users-can-steal-reward-tokens-via-re-entrancy.md -->
<!-- date: 2023-10 -->

**AuditVault finding:** `35121` · `H-8: Malicious users can steal reward tokens via re-entrancy attack`

## Key info

| | |
|---|---|
| **Impact** | **HIGH** — Reward claim reentrancy pays twice |
| **Protocol** | [[Notional]] Leveraged Vaults: Pendle PT and Vault Incentives |
| **Finding** | AuditVault #35121 |
| **Report** | [https://github.com/sherlock-audit/2024-06-leveraged-vaults-judging](https://github.com/sherlock-audit/2024-06-leveraged-vaults-judging) |
| **Source** | [AuditVault finding](https://github.com/Auditware/AuditVault/blob/main/findings/35121-h-8-malicious-users-can-steal-reward-tokens-via-re-entrancy.md) |
| **Compiler** | `^0.8.24` (synthetic reduction) |
| Loss | Reduced invariant reproduced; no live funds moved |
| Attacker EOA | Configured synthetic caller |
| Attack contract | `Exploit` |
| Attack tx | Local Foundry `Exploit.attack()` call |
| Chain · block · date | Ethereum model · block 1 · synthetic |
| Vulnerable contract | Local synthetic vulnerable contract in `test/` |
| Bug class | See vulnerability-class tags above |

## TL;DR

This bug report discusses a vulnerability in which malicious users can steal reward tokens through a re-entrancy attack. The vulnerability is caused by a function that updates account rewards during the redemption of vault shares. The function does not properly check for re-entrancy, allowing an attacker to repeatedly claim reward tokens and receive more than they are entitled to. This can result in the theft of reward tokens from the vault and other shareholders. The vulnerability is valid and has been accepted for resolution with a high severity rating.

## Background

The upstream report is a Solidity finding. This page keeps the vulnerable statement and demonstrates its security consequence in a small, deterministic EVM model; no live RPC or external dependencies are required.

## The vulnerable code

```solidity
// The exact vulnerable pattern is retained in test/35121-h-8-malicious-users-can-steal-reward-tokens-via-re-entrancy.sol.
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
cd evm-hack-registry/35121-h-8-malicious-users-can-steal-reward-tokens-via-re-entrancy_exp
forge test -vvvvv
```

The test is offline and uses only the shared `forge-std` library. The corresponding Playground bundle is generated from `scripts/poc-configs/35121-h-8-malicious-users-can-steal-reward-tokens-via-re-entrancy.mjs`.

## Sources

- [AuditVault finding](https://github.com/Auditware/AuditVault/blob/main/findings/35121-h-8-malicious-users-can-steal-reward-tokens-via-re-entrancy.md)
- [https://github.com/sherlock-audit/2024-06-leveraged-vaults-judging](https://github.com/sherlock-audit/2024-06-leveraged-vaults-judging)
- [Synthetic test](test/35121-h-8-malicious-users-can-steal-reward-tokens-via-re-entrancy.sol)

*Reference: https://github.com/sherlock-audit/2024-06-leveraged-vaults-judging*
