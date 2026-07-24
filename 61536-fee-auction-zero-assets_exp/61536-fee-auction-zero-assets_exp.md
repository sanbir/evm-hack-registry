# CAP Labs — fee auction charges for zero assets

<!-- non-defihacklabs -->
<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/61536-fee-auction-allows-buying-zero-assets-leading-to-front-runni.md -->
<!-- date: 2025-05 -->

> **Vulnerability classes:** vuln/defi/fee-manipulation · vuln/defi/sandwich-attack · vuln/input-validation/missing

> **Reproduction:** Fully local synthetic; run [forge test](.) and inspect [output.txt](output.txt). The Playground bundle replays the same 61536-fee-auction-zero-assets invariant.

## Key info

| Field | Value |
| --- | --- |
| Loss | A losing buyer pays the auction price and receives no basket assets |
| Vulnerable contract | FeeAuction (reconstructed) |
| Attacker EOA | 0x1111111111111111111111111111111111111111 (synthetic caller) |
| Attack contract | [Exploit](test/61536-fee-auction-zero-assets.sol) |
| Attack tx | Local `Exploit.run()` call (no historical transaction) |
| Chain · block · date | Ethereum · local stub 0x1181d03 · 2025-05 |
| Compiler | Solidity 0.8.35 (pragma ^0.8.24) |
| Bug class | vuln/defi/fee-manipulation · vuln/defi/sandwich-attack · vuln/input-validation/missing |

## TL;DR

FeeAuction.buy does not bind a purchase to an auction or require a non-empty basket. A front-runner drains the basket, then the victim pays the doubled price for zero output.

## Background

AuditVault finding [61536-fee-auction-zero-assets](https://github.com/Auditware/AuditVault/blob/main/findings/61536-fee-auction-allows-buying-zero-assets-leading-to-front-runni.md) is an audit-time issue rather than a historical exploit. This write-up reduces the report to one state transition and keeps the claimed harm assertion executable offline.

## The vulnerable code

The minimized source is explicitly marked **RECONSTRUCTED** and preserves the report's blamed operation with an `@> VULN` marker in [test/61536-fee-auction-zero-assets.sol](test/61536-fee-auction-zero-assets.sol). It is byte-identical to the Playground synthetic source. No verified production source was available in this local checkout.

## Root cause

_transferOutAssets only conditionally transfers positive balances and never rejects an all-zero output.

## Preconditions

The affected protocol path is deployed; the attacker can reach the public operation described in the report. The synthetic removes unrelated integrations while preserving the state and authorization assumptions required for the finding.

## Attack walkthrough

1. The first buy drains 100 units; the second still records payment, advances price to 4, and returns zero.
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
cd 61536-fee-auction-zero-assets_exp
forge test -vvv
```

The browser replay uses `scripts/poc-configs/61536-fee-auction-zero-assets.mjs` and the same local-deploy `Exploit` contract.

## Sources

- [AuditVault finding](https://github.com/Auditware/AuditVault/blob/main/findings/61536-fee-auction-allows-buying-zero-assets-leading-to-front-runni.md)
- [Trail of Bits report](https://github.com/trailofbits/publications/blob/master/reviews/2025-05-caplabs-coveredagentprotocol-securityreview.pdf)
- Reduced local source: [test/61536-fee-auction-zero-assets.sol](test/61536-fee-auction-zero-assets.sol)
- Forge regression: [test/61536-fee-auction-zero-assets_exp.sol](test/61536-fee-auction-zero-assets_exp.sol)

