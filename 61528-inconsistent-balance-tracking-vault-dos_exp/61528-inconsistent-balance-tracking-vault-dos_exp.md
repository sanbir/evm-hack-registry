# CAP Labs — inconsistent vault balance tracking bricks borrowing

<!-- non-defihacklabs -->
<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/61528-inconsistent-balance-tracking-in-vault-creates-dos-for-asset.md -->
<!-- date: 2025-05 -->

> **Vulnerability classes:** vuln/logic/state-update · vuln/dos/frozen-funds · vuln/input-validation/missing

> **Reproduction:** Fully local synthetic; run [forge test](.) and inspect [output.txt](output.txt). The Playground bundle replays the same 61528-inconsistent-balance-tracking-vault-dos invariant.

## Key info

| Field | Value |
| --- | --- |
| Loss | Borrowing capacity for the asset is denied (DoS); synthetic invariant reaches available=0 |
| Vulnerable contract | VaultLogic (reconstructed) |
| Attacker EOA | 0x1111111111111111111111111111111111111111 (synthetic caller) |
| Attack contract | [Exploit](test/61528-inconsistent-balance-tracking-vault-dos.sol) |
| Attack tx | Local `Exploit.run()` call (no historical transaction) |
| Chain · block · date | Ethereum · local stub 0x1181d03 · 2025-05 |
| Compiler | Solidity 0.8.35 (pragma ^0.8.24) |
| Bug class | vuln/logic/state-update · vuln/dos/frozen-funds · vuln/input-validation/missing |

## TL;DR

An untracked donation supplies physical tokens for burn, but the burn still decrements totalSupplies. The accounting invariant falls below totalBorrows and subsequent borrowing is disabled.

## Background

AuditVault finding [61528-inconsistent-balance-tracking-vault-dos](https://github.com/Auditware/AuditVault/blob/main/findings/61528-inconsistent-balance-tracking-in-vault-creates-dos-for-asset.md) is an audit-time issue rather than a historical exploit. This write-up reduces the report to one state transition and keeps the claimed harm assertion executable offline.

## The vulnerable code

The minimized source is explicitly marked **RECONSTRUCTED** and preserves the report's blamed operation with an `@> VULN` marker in [test/61528-inconsistent-balance-tracking-vault-dos.sol](test/61528-inconsistent-balance-tracking-vault-dos.sol). It is byte-identical to the Playground synthetic source. No verified production source was available in this local checkout.

## Root cause

burn trusts the transferable balance instead of checking totalSupplies - totalBorrows before decrementing accounting.

## Preconditions

The affected protocol path is deployed; the attacker can reach the public operation described in the report. The synthetic removes unrelated integrations while preserving the state and authorization assumptions required for the finding.

## Attack walkthrough

1. seed(100,90) → donate(5) → burn(15); totalSupplies=85, totalBorrows=90, maxBorrowable=0.
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
cd 61528-inconsistent-balance-tracking-vault-dos_exp
forge test -vvv
```

The browser replay uses `scripts/poc-configs/61528-inconsistent-balance-tracking-vault-dos.mjs` and the same local-deploy `Exploit` contract.

## Sources

- [AuditVault finding](https://github.com/Auditware/AuditVault/blob/main/findings/61528-inconsistent-balance-tracking-in-vault-creates-dos-for-asset.md)
- [Trail of Bits report](https://github.com/trailofbits/publications/blob/master/reviews/2025-05-caplabs-coveredagentprotocol-securityreview.pdf)
- Reduced local source: [test/61528-inconsistent-balance-tracking-vault-dos.sol](test/61528-inconsistent-balance-tracking-vault-dos.sol)
- Forge regression: [test/61528-inconsistent-balance-tracking-vault-dos_exp.sol](test/61528-inconsistent-balance-tracking-vault-dos_exp.sol)

