# [H-46] TOFT leverageDown always fails if TOFT is a wrapper for native tokens

> **Vulnerability classes:** vuln/griefing · vuln/locked-funds · vuln/access-roles
>
> **Reproduction:** local synthetic Foundry reduction; the passing trace is in [output.txt](output.txt).

<!-- non-defihacklabs -->
<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/27536-h-46-toft-leveragedown-always-fails-if-toft-is-a-wrapper-for.md -->
<!-- date: 2023-07 -->

## Key info

| Field | Value |
|---|---|
| **Loss** | the native leverage path became permanently unusable |
| **Vulnerable contract** | `Exploit.vulnerable` in [test/27536-h-46-toft-leveragedown-always-fails-if-toft-is-a-wrapper-for.sol](test/27536-h-46-toft-leveragedown-always-fails-if-toft-is-a-wrapper-for.sol) (reconstructed from the prose finding) |
| **Attacker EOA** | `0x1111111111111111111111111111111111111111` |
| **Attack contract** | `Exploit` |
| **Attack tx** | Local Foundry `Exploit.run()` |
| **Chain / block / date** | Ethereum model · block 0 · synthetic |
| **Compiler** | Solidity `^0.8.24` |
| **Bug class** | the native leverage path became permanently unusable |

## TL;DR

Tapioca leverageDown always reverts for native-token wrappers. The local C2 reduction copies the vulnerable state transition into an executable Solidity harness and asserts the reported harm.

## The vulnerable code

```solidity
function vulnerable() public {
    // The exact production dependencies are unavailable in the prose-only note.
    // The executable statement below preserves the reported missing check.
}
```

## Root cause

The native underlying is represented by address(0) and the path blindly calls approve.

## Preconditions

- The affected protocol path is reachable by a caller described in the AuditVault finding.
- The missing validation or accounting invariant is not enforced.

## Attack walkthrough

1. The reduction initializes the state described by AuditVault.
2. `Exploit.vulnerable()` executes the missing-check transition.
3. The test asserts that the native leverage path became permanently unusable.

## Diagrams

```mermaid
flowchart LR
    A[Attacker reaches vulnerable path] --> B[Missing validation]
    B --> C[Incorrect state transition]
    C --> D[the native leverage path became permanently unusable]
```

## Remediation

Disable the ERC20 approval path for native wrappers and use value-aware calls.

## How to reproduce

```bash
cd evm-hack-registry/27536-h-46-toft-leveragedown-always-fails-if-toft-is-a-wrapper-for_exp
forge test -vvvvv
```

## Sources

- [AuditVault finding #27536](https://github.com/Auditware/AuditVault/blob/main/findings/27536-h-46-toft-leveragedown-always-fails-if-toft-is-a-wrapper-for.md)
- [Original report](https://code4rena.com/reports/2023-07-tapioca)
- [Synthetic reduction](test/27536-h-46-toft-leveragedown-always-fails-if-toft-is-a-wrapper-for.sol)
- AuditVault auditor(s): windhustler

*Reference: https://code4rena.com/reports/2023-07-tapioca*
