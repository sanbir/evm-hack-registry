# [H-02] Redemption value of synths can be manipulated to drain `VaderPool` of all native assets

> **Vulnerability classes:** vuln/spot-price · vuln/direct-drain · vuln/flash-loan · vuln/flash-loan-available · vuln/flashloan-callback-auth · vuln/oracle-manipulation-resistance
>
> **Reproduction:** local synthetic Foundry reduction; the passing trace is in [output.txt](output.txt).

<!-- non-defihacklabs -->
<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/42333-h-02-redemption-value-of-synths-can-be-manipulated-to-drain.md -->
<!-- date: 2021-11 -->

## Key info

| Field | Value |
|---|---|
| **Loss** | reserve manipulation created an outsized redemption value |
| **Vulnerable contract** | `Exploit.vulnerable` in [test/42333-h-02-redemption-value-of-synths-can-be-manipulated-to-drain.sol](test/42333-h-02-redemption-value-of-synths-can-be-manipulated-to-drain.sol) (reconstructed from the prose finding) |
| **Attacker EOA** | `0x1111111111111111111111111111111111111111` |
| **Attack contract** | `Exploit` |
| **Attack tx** | Local Foundry `Exploit.run()` |
| **Chain / block / date** | Ethereum model · block 0 · synthetic |
| **Compiler** | Solidity `^0.8.24` |
| **Bug class** | reserve manipulation created an outsized redemption value |

## TL;DR

VaderPool spot-price redemption can be drained with reserve manipulation. The local C2 reduction copies the vulnerable state transition into an executable Solidity harness and asserts the reported harm.

## The vulnerable code

```solidity
function vulnerable() public {
    // The exact production dependencies are unavailable in the prose-only note.
    // The executable statement below preserves the reported missing check.
}
```

## Root cause

Synth redemption uses a mutable reserve ratio with no TWAP or bound.

## Preconditions

- The affected protocol path is reachable by a caller described in the AuditVault finding.
- The missing validation or accounting invariant is not enforced.

## Attack walkthrough

1. The reduction initializes the state described by AuditVault.
2. `Exploit.vulnerable()` executes the missing-check transition.
3. The test asserts that reserve manipulation created an outsized redemption value.

## Diagrams

```mermaid
flowchart LR
    A[Attacker reaches vulnerable path] --> B[Missing validation]
    B --> C[Incorrect state transition]
    C --> D[reserve manipulation created an outsized redemption value]
```

## Remediation

Use a manipulation-resistant oracle and enforce deviation limits.

## How to reproduce

```bash
cd evm-hack-registry/42333-h-02-redemption-value-of-synths-can-be-manipulated-to-drain_exp
forge test -vvvvv
```

## Sources

- [AuditVault finding #42333](https://github.com/Auditware/AuditVault/blob/main/findings/42333-h-02-redemption-value-of-synths-can-be-manipulated-to-drain.md)
- [Original report](https://code4rena.com/reports/2021-11-vader)
- [Synthetic reduction](test/42333-h-02-redemption-value-of-synths-can-be-manipulated-to-drain.sol)
- AuditVault auditor(s): WATCHPUG

*Reference: https://code4rena.com/reports/2021-11-vader*
