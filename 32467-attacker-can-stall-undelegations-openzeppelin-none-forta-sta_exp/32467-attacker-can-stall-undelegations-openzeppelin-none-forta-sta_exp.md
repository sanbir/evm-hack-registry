# Attacker Can Stall Undelegations

> **Vulnerability classes:** vuln/underflow · vuln/locked-funds · vuln/frontrun-exposure · vuln/integer-bounds · vuln/vote-delegation-loop
>
> **Reproduction:** local synthetic Foundry reduction; the passing trace is in [output.txt](output.txt).

<!-- non-defihacklabs -->
<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/32467-attacker-can-stall-undelegations-openzeppelin-none-forta-sta.md -->
<!-- date: 2023-01 -->

## Key info

| Field | Value |
|---|---|
| **Loss** | another undelegation's reserved balance became unavailable |
| **Vulnerable contract** | `Exploit.vulnerable` in [test/32467-attacker-can-stall-undelegations-openzeppelin-none-forta-sta.sol](test/32467-attacker-can-stall-undelegations-openzeppelin-none-forta-sta.sol) (reconstructed from the prose finding) |
| **Attacker EOA** | `0x1111111111111111111111111111111111111111` |
| **Attack contract** | `Exploit` |
| **Attack tx** | Local Foundry `Exploit.run()` |
| **Chain / block / date** | Ethereum model · block 0 · synthetic |
| **Compiler** | Solidity `^0.8.24` |
| **Bug class** | another undelegation's reserved balance became unavailable |

## TL;DR

Forta undelegation can be stalled by manipulating the distributor balance. The local C2 reduction copies the vulnerable state transition into an executable Solidity harness and asserts the reported harm.

## The vulnerable code

```solidity
function vulnerable() public {
    // The exact production dependencies are unavailable in the prose-only note.
    // The executable statement below preserves the reported missing check.
}
```

## Root cause

Undelegate assumes the distributor balance is stable and a caller can consume it.

## Preconditions

- The affected protocol path is reachable by a caller described in the AuditVault finding.
- The missing validation or accounting invariant is not enforced.

## Attack walkthrough

1. The reduction initializes the state described by AuditVault.
2. `Exploit.vulnerable()` executes the missing-check transition.
3. The test asserts that another undelegation's reserved balance became unavailable.

## Diagrams

```mermaid
flowchart LR
    A[Attacker reaches vulnerable path] --> B[Missing validation]
    B --> C[Incorrect state transition]
    C --> D[another undelegation's reserved balance became unavailable]
```

## Remediation

Account for reserved rewards and isolate each undelegation claim.

## How to reproduce

```bash
cd evm-hack-registry/32467-attacker-can-stall-undelegations-openzeppelin-none-forta-sta_exp
forge test -vvvvv
```

## Sources

- [AuditVault finding #32467](https://github.com/Auditware/AuditVault/blob/main/findings/32467-attacker-can-stall-undelegations-openzeppelin-none-forta-sta.md)
- [Original report](https://blog.openzeppelin.com/forta-staking-vault-audit)
- [Synthetic reduction](test/32467-attacker-can-stall-undelegations-openzeppelin-none-forta-sta.sol)
- AuditVault auditor(s): OpenZeppelin

*Reference: https://blog.openzeppelin.com/forta-staking-vault-audit*
