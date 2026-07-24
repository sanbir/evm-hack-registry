# Origin — arbitrary ERC20 can block offer finalization

<!-- non-defihacklabs -->
<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/17097-remote-code-execution-through-arbitrary-erc20-implementation.md -->
<!-- date: 2022-01 -->

> **Vulnerability classes:** vuln/dependency/unsafe-external-call · vuln/dos/frozen-funds · vuln/input-validation/missing

> **Reproduction:** Fully local synthetic; run [forge test](.) and inspect [output.txt](output.txt). The Playground bundle replays the same 17097-origin-malicious-erc20-finalization-dos invariant.

## Key info

| Field | Value |
| --- | --- |
| Loss | An accepted offer cannot settle when its arbitrary currency reverts on transfer |
| Vulnerable contract | Origin Marketplace (reconstructed) |
| Attacker EOA | 0x1111111111111111111111111111111111111111 (synthetic caller) |
| Attack contract | [Exploit](test/17097-origin-malicious-erc20-finalization-dos.sol) |
| Attack tx | Local `Exploit.run()` call (no historical transaction) |
| Chain · block · date | Ethereum · local stub 0x1181d03 · 2022-01 |
| Compiler | Solidity 0.8.35 (pragma ^0.8.24) |
| Bug class | vuln/dependency/unsafe-external-call · vuln/dos/frozen-funds · vuln/input-validation/missing |

## TL;DR

Offers store any ERC20 address. A malicious token that always reverts on transfer is called during finalization, permanently blocking settlement without an alternate revoke path.

## Background

AuditVault finding [17097-origin-malicious-erc20-finalization-dos](https://github.com/Auditware/AuditVault/blob/main/findings/17097-remote-code-execution-through-arbitrary-erc20-implementation.md) is an audit-time issue rather than a historical exploit. This write-up reduces the report to one state transition and keeps the claimed harm assertion executable offline.

## The vulnerable code

The minimized source is explicitly marked **RECONSTRUCTED** and preserves the report's blamed operation with an `@> VULN` marker in [test/17097-origin-malicious-erc20-finalization-dos.sol](test/17097-origin-malicious-erc20-finalization-dos.sol). It is byte-identical to the Playground synthetic source. No verified production source was available in this local checkout.

## Root cause

makeOffer accepts untrusted currency and finalize performs mandatory transfer calls to it.

## Preconditions

The affected protocol path is deployed; the attacker can reach the public operation described in the report. The synthetic removes unrelated integrations while preserving the state and authorization assumptions required for the finding.

## Attack walkthrough

1. Create an offer with MaliciousERC20, invoke finalize, and catch the token's revert; finalized remains false.
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
cd 17097-origin-malicious-erc20-finalization-dos_exp
forge test -vvv
```

The browser replay uses `scripts/poc-configs/17097-origin-malicious-erc20-finalization-dos.mjs` and the same local-deploy `Exploit` contract.

## Sources

- [AuditVault finding](https://github.com/Auditware/AuditVault/blob/main/findings/17097-remote-code-execution-through-arbitrary-erc20-implementation.md)
- [Trail of Bits report](https://github.com/trailofbits/publications/blob/master/reviews/origin.pdf)
- Reduced local source: [test/17097-origin-malicious-erc20-finalization-dos.sol](test/17097-origin-malicious-erc20-finalization-dos.sol)
- Forge regression: [test/17097-origin-malicious-erc20-finalization-dos_exp.sol](test/17097-origin-malicious-erc20-finalization-dos_exp.sol)

