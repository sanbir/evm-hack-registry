# Liquity — zero-ICR reinsertion strands a trove

<!-- non-defihacklabs -->
<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/18030-troves-can-be-improperly-removed-under-certain-circumstances.md -->
<!-- date: 2021-09 -->

> **Vulnerability classes:** vuln/logic/wrong-condition · vuln/logic/state-update · vuln/dos/frozen-funds

> **Reproduction:** Fully local synthetic; run [forge test](.) and inspect [output.txt](output.txt). The Playground bundle replays the same 18030-liquity-zero-icr-trove-removal invariant.

## Key info

| Field | Value |
| --- | --- |
| Loss | A trove remains recorded by the manager but collateral operations revert |
| Vulnerable contract | SortedTroves (reconstructed) |
| Attacker EOA | 0x1111111111111111111111111111111111111111 (synthetic caller) |
| Attack contract | [Exploit](test/18030-liquity-zero-icr-trove-removal.sol) |
| Attack tx | Local `Exploit.run()` call (no historical transaction) |
| Chain · block · date | Ethereum · local stub 0x1181d03 · 2021-09 |
| Compiler | Solidity 0.8.35 (pragma ^0.8.24) |
| Bug class | vuln/logic/wrong-condition · vuln/logic/state-update · vuln/dos/frozen-funds |

## TL;DR

SortedTroves removes a node and only reinserts it for a positive ICR. A zero-ICR update leaves TroveManager's existence belief inconsistent, so addCollateral and other calls revert.

## Background

AuditVault finding [18030-liquity-zero-icr-trove-removal](https://github.com/Auditware/AuditVault/blob/main/findings/18030-troves-can-be-improperly-removed-under-certain-circumstances.md) is an audit-time issue rather than a historical exploit. This write-up reduces the report to one state transition and keeps the claimed harm assertion executable offline.

## The vulnerable code

The minimized source is explicitly marked **RECONSTRUCTED** and preserves the report's blamed operation with an `@> VULN` marker in [test/18030-liquity-zero-icr-trove-removal.sol](test/18030-liquity-zero-icr-trove-removal.sol). It is byte-identical to the Playground synthetic source. No verified production source was available in this local checkout.

## Root cause

The zero-ICR branch omits reinsertion while other protocol state still assumes the trove is in the sorted list.

## Preconditions

The affected protocol path is deployed; the attacker can reach the public operation described in the report. The synthetic removes unrelated integrations while preserving the state and authorization assumptions required for the finding.

## Attack walkthrough

1. Open the trove, reInsert with ICR=0, and catch addCollateral reverting because contains[id] is false.
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
cd 18030-liquity-zero-icr-trove-removal_exp
forge test -vvv
```

The browser replay uses `scripts/poc-configs/18030-liquity-zero-icr-trove-removal.mjs` and the same local-deploy `Exploit` contract.

## Sources

- [AuditVault finding](https://github.com/Auditware/AuditVault/blob/main/findings/18030-troves-can-be-improperly-removed-under-certain-circumstances.md)
- [Trail of Bits report](https://github.com/trailofbits/publications/blob/master/reviews/Liquity.pdf)
- Reduced local source: [test/18030-liquity-zero-icr-trove-removal.sol](test/18030-liquity-zero-icr-trove-removal.sol)
- Forge regression: [test/18030-liquity-zero-icr-trove-removal_exp.sol](test/18030-liquity-zero-icr-trove-removal_exp.sol)

