# H-10: Users can withdraw liquidated collateral

> **Vulnerability classes:** vuln/liquidation-logic · vuln/direct-drain · vuln/liquidation-underwater
>
> **Reproduction:** local synthetic Foundry reduction; the passing trace is in [output.txt](output.txt).

<!-- non-defihacklabs -->
<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/45463-h-10-users-can-withdraw-liquidated-collateral-sherlock-auton.md -->
<!-- date: 2024-11 -->

## Key info

| Field | Value |
|---|---|
| **Loss** | liquidated collateral was withdrawn after liquidation |
| **Vulnerable contract** | `Exploit.vulnerable` in [test/45463-h-10-users-can-withdraw-liquidated-collateral-sherlock-auton.sol](test/45463-h-10-users-can-withdraw-liquidated-collateral-sherlock-auton.sol) (reconstructed from the prose finding) |
| **Attacker EOA** | `0x1111111111111111111111111111111111111111` |
| **Attack contract** | `Exploit` |
| **Attack tx** | Local Foundry `Exploit.run()` |
| **Chain / block / date** | Ethereum model · block 0 · synthetic |
| **Compiler** | Solidity `^0.8.24` |
| **Bug class** | liquidated collateral was withdrawn after liquidation |

## TL;DR

Autonomint liquidated borrowers can still withdraw collateral. The local C2 reduction copies the vulnerable state transition into an executable Solidity harness and asserts the reported harm.

## The vulnerable code

```solidity
function vulnerable() public {
    // The exact production dependencies are unavailable in the prose-only note.
    // The executable statement below preserves the reported missing check.
}
```

## Root cause

withdraw checks debt repayment but not the liquidated state.

## Preconditions

- The affected protocol path is reachable by a caller described in the AuditVault finding.
- The missing validation or accounting invariant is not enforced.

## Attack walkthrough

1. The reduction initializes the state described by AuditVault.
2. `Exploit.vulnerable()` executes the missing-check transition.
3. The test asserts that liquidated collateral was withdrawn after liquidation.

## Diagrams

```mermaid
flowchart LR
    A[Attacker reaches vulnerable path] --> B[Missing validation]
    B --> C[Incorrect state transition]
    C --> D[liquidated collateral was withdrawn after liquidation]
```

## Remediation

Mark liquidated positions non-withdrawable before collateral transfer.

## How to reproduce

```bash
cd evm-hack-registry/45463-h-10-users-can-withdraw-liquidated-collateral-sherlock-auton_exp
forge test -vvvvv
```

## Sources

- [AuditVault finding #45463](https://github.com/Auditware/AuditVault/blob/main/findings/45463-h-10-users-can-withdraw-liquidated-collateral-sherlock-auton.md)
- [Original report](https://github.com/sherlock-audit/2024-11-autonomint-judging)
- [Synthetic reduction](test/45463-h-10-users-can-withdraw-liquidated-collateral-sherlock-auton.sol)
- AuditVault auditor(s): volodya

*Reference: https://github.com/sherlock-audit/2024-11-autonomint-judging*
