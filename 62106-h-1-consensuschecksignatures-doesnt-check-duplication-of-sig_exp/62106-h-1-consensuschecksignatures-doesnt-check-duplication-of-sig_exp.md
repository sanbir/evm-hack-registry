# Consensus accepts duplicated signers — AuditVault synthetic reduction

> **Vulnerability classes:** vuln/bridge/missing-validation · vuln/auth/signature-validation
>
> **Reproduction:** self-contained Foundry PoC with an offline synthetic contract. Full trace: [output.txt](output.txt).

<!-- non-defihacklabs -->
<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/62106-h-1-consensuschecksignatures-doesnt-check-duplication-of-sig.md -->
<!-- date: 2025-07 -->

**AuditVault finding:** `62106` · `H-1: `Consensus`.`checkSignatures` doesn't check duplication of signers`

## Key info

| | |
|---|---|
| **Impact** | **HIGH** — Consensus accepts duplicated signers |
| **Protocol** | [[Mellow]] Flexible Vaults |
| **Finding** | AuditVault #62106 |
| **Report** | [https://github.com/sherlock-audit/2025-07-mellow-flexible-vaults-judging](https://github.com/sherlock-audit/2025-07-mellow-flexible-vaults-judging) |
| **Source** | [AuditVault finding](https://github.com/Auditware/AuditVault/blob/main/findings/62106-h-1-consensuschecksignatures-doesnt-check-duplication-of-sig.md) |
| **Compiler** | `^0.8.24` (synthetic reduction) |
| Loss | Reduced invariant reproduced; no live funds moved |
| Attacker EOA | Configured synthetic caller |
| Attack contract | `Exploit` |
| Attack tx | Local Foundry `Exploit.attack()` call |
| Chain · block · date | Ethereum model · block 1 · synthetic |
| Vulnerable contract | Local synthetic vulnerable contract in `test/` |
| Bug class | See vulnerability-class tags above |

## TL;DR

This bug report discusses a vulnerability found in the Mellow Flexible Vaults protocol, which was discovered by multiple individuals. The issue lies in the `SignatureQueue.validateOrder` function, which checks signatures using the `Consensus.checkSignatures` function. However, this does not check for duplicated signers, allowing a malicious attacker to bypass the `threshold` check. This vulnerability can be exploited by preparing an incorrect order, obtaining one valid signature, and then using `SignatureDepositQueue` or `SignatureRedeemQueue` with duplicated signatures to successfully execute the order and gain profit. The suggested mitigation is to check for duplication of signers. The protocol team has already addressed this issue in a recent pull request.

## Background

The upstream report is a Solidity finding. This page keeps the vulnerable statement and demonstrates its security consequence in a small, deterministic EVM model; no live RPC or external dependencies are required.

## The vulnerable code

```solidity
// The exact vulnerable pattern is retained in test/62106-h-1-consensuschecksignatures-doesnt-check-duplication-of-sig.sol.
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
cd evm-hack-registry/62106-h-1-consensuschecksignatures-doesnt-check-duplication-of-sig_exp
forge test -vvvvv
```

The test is offline and uses only the shared `forge-std` library. The corresponding Playground bundle is generated from `scripts/poc-configs/62106-h-1-consensuschecksignatures-doesnt-check-duplication-of-sig.mjs`.

## Sources

- [AuditVault finding](https://github.com/Auditware/AuditVault/blob/main/findings/62106-h-1-consensuschecksignatures-doesnt-check-duplication-of-sig.md)
- [https://github.com/sherlock-audit/2025-07-mellow-flexible-vaults-judging](https://github.com/sherlock-audit/2025-07-mellow-flexible-vaults-judging)
- [Synthetic test](test/62106-h-1-consensuschecksignatures-doesnt-check-duplication-of-sig.sol)

*Reference: https://github.com/sherlock-audit/2025-07-mellow-flexible-vaults-judging*
