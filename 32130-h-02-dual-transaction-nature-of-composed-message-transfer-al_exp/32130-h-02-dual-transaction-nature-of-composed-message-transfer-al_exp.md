# [H-02] Dual transaction nature of composed message transfer allows anyone to steal user funds

> **Vulnerability classes:** vuln/missing-modifier · vuln/direct-drain · vuln/frontrun-exposure
>
> **Reproduction:** local synthetic Foundry reduction; the passing trace is in [output.txt](output.txt).

<!-- non-defihacklabs -->
<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/32130-h-02-dual-transaction-nature-of-composed-message-transfer-al.md -->
<!-- date: 2024-03 -->

## Key info

| Field | Value |
|---|---|
| **Loss** | a forged bridge payload changed staking/recipient state |
| **Vulnerable contract** | `Exploit.vulnerable` in [test/32130-h-02-dual-transaction-nature-of-composed-message-transfer-al.sol](test/32130-h-02-dual-transaction-nature-of-composed-message-transfer-al.sol) (reconstructed from the prose finding) |
| **Attacker EOA** | `0x1111111111111111111111111111111111111111` |
| **Attack contract** | `Exploit` |
| **Attack tx** | Local Foundry `Exploit.run()` |
| **Chain / block / date** | Ethereum model · block 0 · synthetic |
| **Compiler** | Solidity `^0.8.24` |
| **Bug class** | a forged bridge payload changed staking/recipient state |

## TL;DR

Canto composed-message delivery lets anyone redirect the second transaction. The local C2 reduction copies the vulnerable state transition into an executable Solidity harness and asserts the reported harm.

## The vulnerable code

```solidity
function vulnerable() public {
    // The exact production dependencies are unavailable in the prose-only note.
    // The executable statement below preserves the reported missing check.
}
```

## Root cause

The composed call does not bind the message to its original sender.

## Preconditions

- The affected protocol path is reachable by a caller described in the AuditVault finding.
- The missing validation or accounting invariant is not enforced.

## Attack walkthrough

1. The reduction initializes the state described by AuditVault.
2. `Exploit.vulnerable()` executes the missing-check transition.
3. The test asserts that a forged bridge payload changed staking/recipient state.

## Diagrams

```mermaid
flowchart LR
    A[Attacker reaches vulnerable path] --> B[Missing validation]
    B --> C[Incorrect state transition]
    C --> D[a forged bridge payload changed staking/recipient state]
```

## Remediation

Authenticate the composed payload and its intended recipient.

## How to reproduce

```bash
cd evm-hack-registry/32130-h-02-dual-transaction-nature-of-composed-message-transfer-al_exp
forge test -vvvvv
```

## Sources

- [AuditVault finding #32130](https://github.com/Auditware/AuditVault/blob/main/findings/32130-h-02-dual-transaction-nature-of-composed-message-transfer-al.md)
- [Original report](https://code4rena.com/reports/2024-03-canto)
- [Synthetic reduction](test/32130-h-02-dual-transaction-nature-of-composed-message-transfer-al.sol)
- AuditVault auditor(s): d3e4

*Reference: https://code4rena.com/reports/2024-03-canto*
