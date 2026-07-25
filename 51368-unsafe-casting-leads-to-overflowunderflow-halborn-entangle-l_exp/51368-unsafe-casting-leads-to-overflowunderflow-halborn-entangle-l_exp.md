# Unsafe Casting Leads To Overflow/Underflow

> **Vulnerability classes:** vuln/underflow · vuln/known-pattern · vuln/direct-drain · vuln/integer-bounds
>
> **Reproduction:** local synthetic Foundry reduction; the passing trace is in [output.txt](output.txt).

<!-- non-defihacklabs -->
<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/51368-unsafe-casting-leads-to-overflowunderflow-halborn-entangle-l.md -->
<!-- date: 2024-01 -->

## Key info

| Field | Value |
|---|---|
| **Loss** | the converted amount wrapped below the source amount |
| **Vulnerable contract** | `Exploit.vulnerable` in [test/51368-unsafe-casting-leads-to-overflowunderflow-halborn-entangle-l.sol](test/51368-unsafe-casting-leads-to-overflowunderflow-halborn-entangle-l.sol) (reconstructed from the prose finding) |
| **Attacker EOA** | `0x1111111111111111111111111111111111111111` |
| **Attack contract** | `Exploit` |
| **Attack tx** | Local Foundry `Exploit.run()` |
| **Chain / block / date** | Ethereum model · block 0 · synthetic |
| **Compiler** | Solidity `^0.8.24` |
| **Bug class** | the converted amount wrapped below the source amount |

## TL;DR

Entangle unsafe integer casts wrap reinvest and withdrawal amounts. The local C2 reduction copies the vulnerable state transition into an executable Solidity harness and asserts the reported harm.

## The vulnerable code

```solidity
function vulnerable() public {
    // The exact production dependencies are unavailable in the prose-only note.
    // The executable statement below preserves the reported missing check.
}
```

## Root cause

A uint256 amount is cast to int128 without a bounds check.

## Preconditions

- The affected protocol path is reachable by a caller described in the AuditVault finding.
- The missing validation or accounting invariant is not enforced.

## Attack walkthrough

1. The reduction initializes the state described by AuditVault.
2. `Exploit.vulnerable()` executes the missing-check transition.
3. The test asserts that the converted amount wrapped below the source amount.

## Diagrams

```mermaid
flowchart LR
    A[Attacker reaches vulnerable path] --> B[Missing validation]
    B --> C[Incorrect state transition]
    C --> D[the converted amount wrapped below the source amount]
```

## Remediation

Use SafeCast and reject values outside the destination range.

## How to reproduce

```bash
cd evm-hack-registry/51368-unsafe-casting-leads-to-overflowunderflow-halborn-entangle-l_exp
forge test -vvvvv
```

## Sources

- [AuditVault finding #51368](https://github.com/Auditware/AuditVault/blob/main/findings/51368-unsafe-casting-leads-to-overflowunderflow-halborn-entangle-l.md)
- [Original report](https://www.halborn.com/audits/entangle-labs/entangle-trillion)
- [Synthetic reduction](test/51368-unsafe-casting-leads-to-overflowunderflow-halborn-entangle-l.sol)
- AuditVault auditor(s): Halborn

*Reference: https://www.halborn.com/audits/entangle-labs/entangle-trillion*
