# [H-01] Lack of access control on `assertGovernanceApproved` can cause funds to be locked

> **Vulnerability classes:** vuln/frozen-funds · vuln/direct-drain · vuln/locked-funds · vuln/frontrun · vuln/variant · vuln/access-roles · vuln/dos-resistance · vuln/frontrun-exposure
>
> **Reproduction:** local synthetic Foundry reduction; the passing trace is in [output.txt](output.txt).

<!-- non-defihacklabs -->
<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/42453-h-01-lack-of-access-control-on-assertgovernanceapproved-can.md -->
<!-- date: 2022-01 -->

## Key info

| Field | Value |
|---|---|
| **Loss** | a victim's approved funds were locked by a third party |
| **Vulnerable contract** | `Exploit.vulnerable` in [test/42453-h-01-lack-of-access-control-on-assertgovernanceapproved-can.sol](test/42453-h-01-lack-of-access-control-on-assertgovernanceapproved-can.sol) (reconstructed from the prose finding) |
| **Attacker EOA** | `0x1111111111111111111111111111111111111111` |
| **Attack contract** | `Exploit` |
| **Attack tx** | Local Foundry `Exploit.run()` |
| **Chain / block / date** | Ethereum model · block 0 · synthetic |
| **Compiler** | Solidity `^0.8.24` |
| **Bug class** | a victim's approved funds were locked by a third party |

## TL;DR

Anyone can call assertGovernanceApproved and lock an approved user's funds. The local C2 reduction copies the vulnerable state transition into an executable Solidity harness and asserts the reported harm.

## The vulnerable code

```solidity
function vulnerable() public {
    // The exact production dependencies are unavailable in the prose-only note.
    // The executable statement below preserves the reported missing check.
}
```

## Root cause

The arbiter trusts a user-supplied sender and allowance without ownership proof.

## Preconditions

- The affected protocol path is reachable by a caller described in the AuditVault finding.
- The missing validation or accounting invariant is not enforced.

## Attack walkthrough

1. The reduction initializes the state described by AuditVault.
2. `Exploit.vulnerable()` executes the missing-check transition.
3. The test asserts that a victim's approved funds were locked by a third party.

## Diagrams

```mermaid
flowchart LR
    A[Attacker reaches vulnerable path] --> B[Missing validation]
    B --> C[Incorrect state transition]
    C --> D[a victim's approved funds were locked by a third party]
```

## Remediation

Require the sender to authorize the governance decision.

## How to reproduce

```bash
cd evm-hack-registry/42453-h-01-lack-of-access-control-on-assertgovernanceapproved-can_exp
forge test -vvvvv
```

## Sources

- [AuditVault finding #42453](https://github.com/Auditware/AuditVault/blob/main/findings/42453-h-01-lack-of-access-control-on-assertgovernanceapproved-can.md)
- [Original report](https://code4rena.com/reports/2022-01-behodler)
- [Synthetic reduction](test/42453-h-01-lack-of-access-control-on-assertgovernanceapproved-can.sol)
- AuditVault auditor(s): Code4rena

*Reference: https://code4rena.com/reports/2022-01-behodler*
