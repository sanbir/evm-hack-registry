# CAP Labs — health and slashable collateral disagree

<!-- non-defihacklabs -->
<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/61537-discrepancy-between-health-calculation-and-slashable-collate.md -->
<!-- date: 2025-05 -->

> **Vulnerability classes:** vuln/logic/incorrect-state-transition · vuln/logic/state-update · vuln/dos/frozen-funds

> **Reproduction:** Fully local synthetic; run [forge test](.) and inspect [output.txt](output.txt). The Playground bundle replays the same 61537-health-vs-slashable-collateral invariant.

## Key info

| Field | Value |
| --- | --- |
| Loss | Liquidation leaves fresh collateral protected; the protocol absorbs the uncovered amount |
| Vulnerable contract | Delegation/NetworkMiddleware (reconstructed) |
| Attacker EOA | 0x1111111111111111111111111111111111111111 (synthetic caller) |
| Attack contract | [Exploit](test/61537-health-vs-slashable-collateral.sol) |
| Attack tx | Local `Exploit.run()` call (no historical transaction) |
| Chain · block · date | Ethereum · local stub 0x1181d03 · 2025-05 |
| Compiler | Solidity 0.8.35 (pragma ^0.8.24) |
| Bug class | vuln/logic/incorrect-state-transition · vuln/logic/state-update · vuln/dos/frozen-funds |

## TL;DR

coverage includes current collateral while slashTimestamp limits slashing to the previous epoch. A fresh rescue deposit improves health but cannot be slashed in liquidation.

## Background

AuditVault finding [61537-health-vs-slashable-collateral](https://github.com/Auditware/AuditVault/blob/main/findings/61537-discrepancy-between-health-calculation-and-slashable-collate.md) is an audit-time issue rather than a historical exploit. This write-up reduces the report to one state transition and keeps the claimed harm assertion executable offline.

## The vulnerable code

The minimized source is explicitly marked **RECONSTRUCTED** and preserves the report's blamed operation with an `@> VULN` marker in [test/61537-health-vs-slashable-collateral.sol](test/61537-health-vs-slashable-collateral.sol). It is byte-identical to the Playground synthetic source. No verified production source was available in this local checkout.

## Root cause

The two calculations use different time bases: current coverage versus historical slashable deposits.

## Preconditions

The affected protocol path is deployed; the attacker can reach the public operation described in the report. The synthetic removes unrelated integrations while preserving the state and authorization assumptions required for the finding.

## Attack walkthrough

1. 100 mature + 50 fresh collateral gives coverage 150 but only 100 slashable; liquidation leaves the mismatch.
2. The `run()` method requires the broken invariant and sets `confirmed`; the Forge trace records a passing test at [output.txt:355](output.txt).
3. The remediation is to validate the accounting/state transition before accepting the external call or to consume the one-time state.

## Diagrams

```mermaid
flowchart TD
    A["Attacker invokes public path"] --> B["Vulnerable state transition"]
    B --> C["Inconsistent accounting or revert"]
    C --> D["Reported protocol harm"]
```

## Remediation

Validate external addresses and returned balances before updating state, and make each one-time transition explicit. Add invariant tests covering zero/deflationary/epoch-boundary inputs.

## How to reproduce

```bash
cd 61537-health-vs-slashable-collateral_exp
forge test -vvv
```

The browser replay uses `scripts/poc-configs/61537-health-vs-slashable-collateral.mjs` and the same local-deploy `Exploit` contract.

## Sources

- [AuditVault finding](https://github.com/Auditware/AuditVault/blob/main/findings/61537-discrepancy-between-health-calculation-and-slashable-collate.md)
- [Trail of Bits report](https://github.com/trailofbits/publications/blob/master/reviews/2025-05-caplabs-coveredagentprotocol-securityreview.pdf)
- Reduced local source: [test/61537-health-vs-slashable-collateral.sol](test/61537-health-vs-slashable-collateral.sol)
- Forge regression: [test/61537-health-vs-slashable-collateral_exp.sol](test/61537-health-vs-slashable-collateral_exp.sol)

