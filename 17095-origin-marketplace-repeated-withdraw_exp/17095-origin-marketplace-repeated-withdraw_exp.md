# Origin — listing deposit can be withdrawn repeatedly

<!-- non-defihacklabs -->
<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/17095-marketplace-ogn-balance-is-drainable-through-withdrawlisting.md -->
<!-- date: 2022-01 -->

> **Vulnerability classes:** vuln/logic/state-update · vuln/logic/missing-check · vuln/logic/wrong-condition

> **Reproduction:** Fully local synthetic; run [forge test](.) and inspect [output.txt](output.txt). The Playground bundle replays the same 17095-origin-marketplace-repeated-withdraw invariant.

## Key info

| Field | Value |
| --- | --- |
| Loss | The marketplace's 100 OGN reserve is drained by replaying one 20 OGN withdrawal |
| Vulnerable contract | Marketplace (reconstructed) |
| Attacker EOA | 0x1111111111111111111111111111111111111111 (synthetic caller) |
| Attack contract | [Exploit](test/17095-origin-marketplace-repeated-withdraw.sol) |
| Attack tx | Local `Exploit.run()` call (no historical transaction) |
| Chain · block · date | Ethereum · local stub 0x1181d03 · 2022-01 |
| Compiler | Solidity 0.8.35 (pragma ^0.8.24) |
| Bug class | vuln/logic/state-update · vuln/logic/missing-check · vuln/logic/wrong-condition |

## TL;DR

withdrawListing authorizes the deposit manager but never marks the listing withdrawn. The same deposit can be transferred six times, draining the marketplace reserve.

## Background

AuditVault finding [17095-origin-marketplace-repeated-withdraw](https://github.com/Auditware/AuditVault/blob/main/findings/17095-marketplace-ogn-balance-is-drainable-through-withdrawlisting.md) is an audit-time issue rather than a historical exploit. This write-up reduces the report to one state transition and keeps the claimed harm assertion executable offline.

## The vulnerable code

The minimized source is explicitly marked **RECONSTRUCTED** and preserves the report's blamed operation with an `@> VULN` marker in [test/17095-origin-marketplace-repeated-withdraw.sol](test/17095-origin-marketplace-repeated-withdraw.sol). It is byte-identical to the Playground synthetic source. No verified production source was available in this local checkout.

## Root cause

The function transfers listing.deposit without a consumed/withdrawn state transition.

## Preconditions

The affected protocol path is deployed; the attacker can reach the public operation described in the report. The synthetic removes unrelated integrations while preserving the state and authorization assumptions required for the finding.

## Attack walkthrough

1. Create a 20-unit listing, repeat withdrawListing six times, and recover 120 units against a 100-unit reserve.
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
cd 17095-origin-marketplace-repeated-withdraw_exp
forge test -vvv
```

The browser replay uses `scripts/poc-configs/17095-origin-marketplace-repeated-withdraw.mjs` and the same local-deploy `Exploit` contract.

## Sources

- [AuditVault finding](https://github.com/Auditware/AuditVault/blob/main/findings/17095-marketplace-ogn-balance-is-drainable-through-withdrawlisting.md)
- [Trail of Bits report](https://github.com/trailofbits/publications/blob/master/reviews/origin.pdf)
- Reduced local source: [test/17095-origin-marketplace-repeated-withdraw.sol](test/17095-origin-marketplace-repeated-withdraw.sol)
- Forge regression: [test/17095-origin-marketplace-repeated-withdraw_exp.sol](test/17095-origin-marketplace-repeated-withdraw_exp.sol)
