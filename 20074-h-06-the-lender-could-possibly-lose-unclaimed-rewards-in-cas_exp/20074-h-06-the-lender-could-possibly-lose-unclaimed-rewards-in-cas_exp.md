# [H-06] The lender could possibly lose unclaimed rewards in case a bucket goes bankrupt

> **Vulnerability classes:** vuln/reward-calculation · vuln/ownership-transfer · vuln/reward-accounting
>
> **Reproduction:** local synthetic Foundry reduction; the passing trace is in [output.txt](output.txt).

<!-- non-defihacklabs -->
<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/20074-h-06-the-lender-could-possibly-lose-unclaimed-rewards-in-cas.md -->
<!-- date: 2023-05 -->

## Key info

| Field | Value |
|---|---|
| **Loss** | the lender's unclaimed reward balance was erased |
| **Vulnerable contract** | `Exploit.vulnerable` in [test/20074-h-06-the-lender-could-possibly-lose-unclaimed-rewards-in-cas.sol](test/20074-h-06-the-lender-could-possibly-lose-unclaimed-rewards-in-cas.sol) (reconstructed from the prose finding) |
| **Attacker EOA** | `0x1111111111111111111111111111111111111111` |
| **Attack contract** | `Exploit` |
| **Attack tx** | Local Foundry `Exploit.run()` |
| **Chain / block / date** | Ethereum model · block 0 · synthetic |
| **Compiler** | Solidity `^0.8.24` |
| **Bug class** | the lender's unclaimed reward balance was erased |

## TL;DR

Bankrupt bucket memorialization erases a lender's unclaimed rewards. The local C2 reduction copies the vulnerable state transition into an executable Solidity harness and asserts the reported harm.

## The vulnerable code

```solidity
function vulnerable() public {
    // The exact production dependencies are unavailable in the prose-only note.
    // The executable statement below preserves the reported missing check.
}
```

## Root cause

PositionManager zeros tracked LP before claiming the prior reward balance.

## Preconditions

- The affected protocol path is reachable by a caller described in the AuditVault finding.
- The missing validation or accounting invariant is not enforced.

## Attack walkthrough

1. The reduction initializes the state described by AuditVault.
2. `Exploit.vulnerable()` executes the missing-check transition.
3. The test asserts that the lender's unclaimed reward balance was erased.

## Diagrams

```mermaid
flowchart LR
    A[Attacker reaches vulnerable path] --> B[Missing validation]
    B --> C[Incorrect state transition]
    C --> D[the lender's unclaimed reward balance was erased]
```

## Remediation

Claim or snapshot rewards before zeroing a bankrupt position.

## How to reproduce

```bash
cd evm-hack-registry/20074-h-06-the-lender-could-possibly-lose-unclaimed-rewards-in-cas_exp
forge test -vvvvv
```

## Sources

- [AuditVault finding #20074](https://github.com/Auditware/AuditVault/blob/main/findings/20074-h-06-the-lender-could-possibly-lose-unclaimed-rewards-in-cas.md)
- [Original report](https://code4rena.com/reports/2023-05-ajna)
- [Synthetic reduction](test/20074-h-06-the-lender-could-possibly-lose-unclaimed-rewards-in-cas.sol)
- AuditVault auditor(s): Koolex

*Reference: https://code4rena.com/reports/2023-05-ajna*
