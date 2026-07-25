# [H-01] Availability of deposit invariant can be bypassed

> **Vulnerability classes:** vuln/wrong-condition · vuln/backrun · vuln/frontrun · vuln/sandwich · vuln/defi/sandwich-attack · vuln/frontrun-exposure
>
> **Reproduction:** local synthetic Foundry reduction; the passing trace is in [output.txt](output.txt).

<!-- non-defihacklabs -->
<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/33354-h-01-availability-of-deposit-invariant-can-be-bypassed-code4.md -->
<!-- date: 2024-05 -->

## Key info

| Field | Value |
|---|---|
| **Loss** | the redemption path consumed an unavailable or unaccounted asset |
| **Vulnerable contract** | `Exploit.vulnerable` in [test/33354-h-01-availability-of-deposit-invariant-can-be-bypassed-code4.sol](test/33354-h-01-availability-of-deposit-invariant-can-be-bypassed-code4.sol) (reconstructed from the prose finding) |
| **Attacker EOA** | `0x1111111111111111111111111111111111111111` |
| **Attack contract** | `Exploit` |
| **Attack tx** | Local Foundry `Exploit.run()` |
| **Chain / block / date** | Ethereum model · block 0 · synthetic |
| **Compiler** | Solidity `^0.8.24` |
| **Bug class** | the redemption path consumed an unavailable or unaccounted asset |

## TL;DR

LoopFi deposit availability invariant can be bypassed with a donation. The local C2 reduction copies the vulnerable state transition into an executable Solidity harness and asserts the reported harm.

## The vulnerable code

```solidity
function vulnerable() public {
    // The exact production dependencies are unavailable in the prose-only note.
    // The executable statement below preserves the reported missing check.
}
```

## Root cause

A direct donation changes the claimable balance without updating the locked position.

## Preconditions

- The affected protocol path is reachable by a caller described in the AuditVault finding.
- The missing validation or accounting invariant is not enforced.

## Attack walkthrough

1. The reduction initializes the state described by AuditVault.
2. `Exploit.vulnerable()` executes the missing-check transition.
3. The test asserts that the redemption path consumed an unavailable or unaccounted asset.

## Diagrams

```mermaid
flowchart LR
    A[Attacker reaches vulnerable path] --> B[Missing validation]
    B --> C[Incorrect state transition]
    C --> D[the redemption path consumed an unavailable or unaccounted asset]
```

## Remediation

Track accounted assets separately from unsolicited donations.

## How to reproduce

```bash
cd evm-hack-registry/33354-h-01-availability-of-deposit-invariant-can-be-bypassed-code4_exp
forge test -vvvvv
```

## Sources

- [AuditVault finding #33354](https://github.com/Auditware/AuditVault/blob/main/findings/33354-h-01-availability-of-deposit-invariant-can-be-bypassed-code4.md)
- [Original report](https://code4rena.com/reports/2024-05-loop)
- [Synthetic reduction](test/33354-h-01-availability-of-deposit-invariant-can-be-bypassed-code4.sol)
- AuditVault auditor(s): 0xnev

*Reference: https://code4rena.com/reports/2024-05-loop*
