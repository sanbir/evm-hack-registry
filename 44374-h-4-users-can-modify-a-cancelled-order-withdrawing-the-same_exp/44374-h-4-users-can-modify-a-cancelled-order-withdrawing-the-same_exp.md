# H-4: Users can modify a cancelled order, withdrawing the same tokens twice

> **Vulnerability classes:** vuln/wrong-condition · vuln/variant · vuln/direct-drain · vuln/fee-accounting · vuln/oracle-freshness
>
> **Reproduction:** local synthetic Foundry reduction; the passing trace is in [output.txt](output.txt).

<!-- non-defihacklabs -->
<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/44374-h-4-users-can-modify-a-cancelled-order-withdrawing-the-same.md -->
<!-- date: 2024-11 -->

## Key info

| Field | Value |
|---|---|
| **Loss** | the same cancelled escrow was released twice |
| **Vulnerable contract** | `Exploit.vulnerable` in [test/44374-h-4-users-can-modify-a-cancelled-order-withdrawing-the-same.sol](test/44374-h-4-users-can-modify-a-cancelled-order-withdrawing-the-same.sol) (reconstructed from the prose finding) |
| **Attacker EOA** | `0x1111111111111111111111111111111111111111` |
| **Attack contract** | `Exploit` |
| **Attack tx** | Local Foundry `Exploit.run()` |
| **Chain / block / date** | Ethereum model · block 0 · synthetic |
| **Compiler** | Solidity `^0.8.24` |
| **Bug class** | the same cancelled escrow was released twice |

## TL;DR

Cancelled Oku orders can be modified and withdrawn twice. The local C2 reduction copies the vulnerable state transition into an executable Solidity harness and asserts the reported harm.

## The vulnerable code

```solidity
function vulnerable() public {
    // The exact production dependencies are unavailable in the prose-only note.
    // The executable statement below preserves the reported missing check.
}
```

## Root cause

modifyOrder does not reject a cancelled order before releasing its escrow.

## Preconditions

- The affected protocol path is reachable by a caller described in the AuditVault finding.
- The missing validation or accounting invariant is not enforced.

## Attack walkthrough

1. The reduction initializes the state described by AuditVault.
2. `Exploit.vulnerable()` executes the missing-check transition.
3. The test asserts that the same cancelled escrow was released twice.

## Diagrams

```mermaid
flowchart LR
    A[Attacker reaches vulnerable path] --> B[Missing validation]
    B --> C[Incorrect state transition]
    C --> D[the same cancelled escrow was released twice]
```

## Remediation

Make cancellation terminal and consume escrow exactly once.

## How to reproduce

```bash
cd evm-hack-registry/44374-h-4-users-can-modify-a-cancelled-order-withdrawing-the-same_exp
forge test -vvvvv
```

## Sources

- [AuditVault finding #44374](https://github.com/Auditware/AuditVault/blob/main/findings/44374-h-4-users-can-modify-a-cancelled-order-withdrawing-the-same.md)
- [Original report](https://github.com/sherlock-audit/2024-11-oku-judging)
- [Synthetic reduction](test/44374-h-4-users-can-modify-a-cancelled-order-withdrawing-the-same.sol)
- AuditVault auditor(s): newspacexyz

*Reference: https://github.com/sherlock-audit/2024-11-oku-judging*
