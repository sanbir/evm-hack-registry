# Folks Finance loan-health underestimation — AuditVault 61051

<!-- non-defihacklabs -->
<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/61051.md -->
<!-- date: 2025-01 -->

> **Vulnerability classes:** vuln/logic/liquidation-logic · vuln/arithmetic/precision-loss

> **Reproduction:** Fully local synthetic reduction. Run `forge test -vvv` in this folder; no live RPC is required.

## Key info

| Field | Value |
| --- | --- |
| Protocol | Audit finding 61051 |
| Impact | High |
| Loss | Reduced invariant reproduced; no live funds moved |
| Attacker EOA | Configured synthetic caller |
| Attack contract | `Exploit` |
| Attack tx | Local Foundry `Exploit.attack()` call |
| Chain · block · date | Ethereum model · block 1 · synthetic |
| Bug class | See vulnerability-class tags above |
| Vulnerable contract | `Vulnerable` in `test/61051-folks-unlimited-loan-health.sol` |
| Attack contract | `Exploit` |
| Compiler | Solidity 0.8.24 |
| Reproduction | Local reduced model |

## TL;DR

The health calculation overstates collateral capacity and permits an outsized loan for a minimal deposit.

## Background

The report identifies a state/accounting boundary that can be reached by an untrusted caller. This self-contained model keeps the relevant variables and call ordering while removing unrelated protocol dependencies.

## The vulnerable code

The minimized victim and attack contracts are in [test/61051-folks-unlimited-loan-health.sol](test/61051-folks-unlimited-loan-health.sol). The marked operation is executed by `Exploit.attack()` and asserted by the Foundry test.

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
- AuditVault finding: https://github.com/Auditware/AuditVault/blob/main/findings/61051.md
- Original report: https://github.com/immunefi-team/Past-Audit-Competitions/blob/main/Folks%20Finance/Boost%20_%20Folks%20Finance%2033816%20-%20%5BSmart%20Contract%20-%20Critical%5D%20Attacker%20can%20get%20unlimited%20loan%20for%20some%20minimum%20deposit%20due%20to%20the%20incorrect%20calculation%20of%20user%20health%20in%20getLoanLiquidity.md
- Synthetic reduction: test/61051-folks-unlimited-loan-health.sol (local reduction)

*Reference: [AuditVault finding 61051](https://github.com/Auditware/AuditVault/blob/main/findings/61051.md)*
