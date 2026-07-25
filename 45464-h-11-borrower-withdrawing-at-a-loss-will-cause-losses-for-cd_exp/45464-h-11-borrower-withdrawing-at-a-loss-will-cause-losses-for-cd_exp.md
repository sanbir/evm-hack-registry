# H-11: Borrower withdrawing at a loss will cause losses for cds depositors that only withdraw after the price recovers

> **Vulnerability classes:** vuln/liquidation-logic · vuln/first-deposit · vuln/direct-drain · vuln/integer-bounds
>
> **Reproduction:** local synthetic Foundry reduction; the passing trace is in [output.txt](output.txt).

<!-- non-defihacklabs -->
<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/45464-h-11-borrower-withdrawing-at-a-loss-will-cause-losses-for-cd.md -->
<!-- date: 2024-11 -->

## Key info

| Field | Value |
|---|---|
| **Loss** | CDS depositor protection was consumed by an already realized loss |
| **Vulnerable contract** | `Exploit.vulnerable` in [test/45464-h-11-borrower-withdrawing-at-a-loss-will-cause-losses-for-cd.sol](test/45464-h-11-borrower-withdrawing-at-a-loss-will-cause-losses-for-cd.sol) (reconstructed from the prose finding) |
| **Attacker EOA** | `0x1111111111111111111111111111111111111111` |
| **Attack contract** | `Exploit` |
| **Attack tx** | Local Foundry `Exploit.run()` |
| **Chain / block / date** | Ethereum model · block 0 · synthetic |
| **Compiler** | Solidity `^0.8.24` |
| **Bug class** | CDS depositor protection was consumed by an already realized loss |

## TL;DR

Autonomint loss withdrawal shifts borrower losses onto CDS depositors. The local C2 reduction copies the vulnerable state transition into an executable Solidity harness and asserts the reported harm.

## The vulnerable code

```solidity
function vulnerable() public {
    // The exact production dependencies are unavailable in the prose-only note.
    // The executable statement below preserves the reported missing check.
}
```

## Root cause

The accounting restores borrower value when the price recovers without reserving the loss.

## Preconditions

- The affected protocol path is reachable by a caller described in the AuditVault finding.
- The missing validation or accounting invariant is not enforced.

## Attack walkthrough

1. The reduction initializes the state described by AuditVault.
2. `Exploit.vulnerable()` executes the missing-check transition.
3. The test asserts that CDS depositor protection was consumed by an already realized loss.

## Diagrams

```mermaid
flowchart LR
    A[Attacker reaches vulnerable path] --> B[Missing validation]
    B --> C[Incorrect state transition]
    C --> D[CDS depositor protection was consumed by an already realized loss]
```

## Remediation

Snapshot and settle the loss at withdrawal time.

## How to reproduce

```bash
cd evm-hack-registry/45464-h-11-borrower-withdrawing-at-a-loss-will-cause-losses-for-cd_exp
forge test -vvvvv
```

## Sources

- [AuditVault finding #45464](https://github.com/Auditware/AuditVault/blob/main/findings/45464-h-11-borrower-withdrawing-at-a-loss-will-cause-losses-for-cd.md)
- [Original report](https://github.com/sherlock-audit/2024-11-autonomint-judging)
- [Synthetic reduction](test/45464-h-11-borrower-withdrawing-at-a-loss-will-cause-losses-for-cd.sol)
- AuditVault auditor(s): 0x73696d616f

*Reference: https://github.com/sherlock-audit/2024-11-autonomint-judging*
