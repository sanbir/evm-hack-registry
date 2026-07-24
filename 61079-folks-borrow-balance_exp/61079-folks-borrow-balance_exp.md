# Folks Finance borrow balance omits interest — AuditVault 61079

<!-- non-defihacklabs -->
<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/61079.md -->
<!-- date: 2025-01 -->

> **Vulnerability classes:** vuln/logic/incorrect-state-transition · vuln/arithmetic/precision-loss

> **Reproduction:** Fully local synthetic reduction. Run `forge test -vvv` in this folder; no live RPC is required.

## Key info

| Field | Value |
| --- | --- |
| Protocol | Audit finding 61079 |
| Impact | High |
| Loss | Reduced invariant reproduced; no live funds moved |
| Attacker EOA | Configured synthetic caller |
| Attack contract | `Exploit` |
| Attack tx | Local Foundry `Exploit.attack()` call |
| Chain · block · date | Ethereum model · block 1 · synthetic |
| Bug class | See vulnerability-class tags above |
| Vulnerable contract | `Vulnerable` in `test/61079-folks-borrow-balance.sol` |
| Attack contract | `Exploit` |
| Compiler | Solidity 0.8.24 |
| Reproduction | Local reduced model |

## TL;DR

getLoanLiquidity reports only principal and drops accrued interest from the borrow balance.

## Background

The report identifies a state/accounting boundary that can be reached by an untrusted caller. This self-contained model keeps the relevant variables and call ordering while removing unrelated protocol dependencies.

## The vulnerable code

The minimized victim and attack contracts are in [test/61079-folks-borrow-balance.sol](test/61079-folks-borrow-balance.sol). The marked operation is executed by `Exploit.attack()` and asserted by the Foundry test.

## Root cause

The vulnerable operation omits the validation or state update required by the report, so the resulting state no longer matches the intended invariant.

## Preconditions

The affected entry point is deployed and reachable; no privileged role is needed in this reduced reproduction.

## Attack walkthrough

1. Deploy the reduced victim from `Exploit`.
2. Execute the reported call sequence.
3. Assert the resulting state mismatch in `test_exploit`.

## Diagrams

```mermaid
flowchart TD
    A[Attacker] --> B[Vulnerable entry point]
    B --> C[Missing check or state update]
    C --> D[Incorrect state / denial of service]
```

## Remediation

Validate caller-controlled inputs and perform the accounting/state transition atomically before any external effect. Add a regression test for the reported invariant.

## How to reproduce

```bash
forge test -vvv
```

## Sources
- AuditVault finding: https://github.com/Auditware/AuditVault/blob/main/findings/61079.md
- Original report: https://github.com/immunefi-team/Past-Audit-Competitions/blob/main/Folks%20Finance/Boost%20_%20Folks%20Finance%2034122%20-%20%5BSmart%20Contract%20-%20High%5D%20Wrong%20borrow%20balance%20calculation%20in%20the%20getLoanLiquidity%20function.md
- Synthetic reduction: test/61079-folks-borrow-balance.sol (local reduction)

*Reference: [AuditVault finding 61079](https://github.com/Auditware/AuditVault/blob/main/findings/61079.md)*
