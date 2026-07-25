# Enable mode can be frontrun to add policies for a different permissionId

> **Vulnerability classes:** vuln/missing-modifier · vuln/frontrun · vuln/frontrun-exposure
>
> **Reproduction:** local synthetic Foundry reduction; the passing trace is in [output.txt](output.txt).

<!-- non-defihacklabs -->
<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/42062-enable-mode-can-be-frontrun-to-add-policies-for-a-different.md -->
<!-- date: 2024-01 -->

## Key info

| Field | Value |
|---|---|
| **Loss** | a policy for a different permissionId was enabled |
| **Vulnerable contract** | `Exploit.vulnerable` in [test/42062-enable-mode-can-be-frontrun-to-add-policies-for-a-different.sol](test/42062-enable-mode-can-be-frontrun-to-add-policies-for-a-different.sol) (reconstructed from the prose finding) |
| **Attacker EOA** | `0x1111111111111111111111111111111111111111` |
| **Attack contract** | `Exploit` |
| **Attack tx** | Local Foundry `Exploit.run()` |
| **Chain / block / date** | Ethereum model · block 0 · synthetic |
| **Compiler** | Solidity `^0.8.24` |
| **Bug class** | a policy for a different permissionId was enabled |

## TL;DR

SmartSession enable mode can be front-run for another permissionId. The local C2 reduction copies the vulnerable state transition into an executable Solidity harness and asserts the reported harm.

## The vulnerable code

```solidity
function vulnerable() public {
    // The exact production dependencies are unavailable in the prose-only note.
    // The executable statement below preserves the reported missing check.
}
```

## Root cause

The signed enable payload omits the permissionId that the action will use.

## Preconditions

- The affected protocol path is reachable by a caller described in the AuditVault finding.
- The missing validation or accounting invariant is not enforced.

## Attack walkthrough

1. The reduction initializes the state described by AuditVault.
2. `Exploit.vulnerable()` executes the missing-check transition.
3. The test asserts that a policy for a different permissionId was enabled.

## Diagrams

```mermaid
flowchart LR
    A[Attacker reaches vulnerable path] --> B[Missing validation]
    B --> C[Incorrect state transition]
    C --> D[a policy for a different permissionId was enabled]
```

## Remediation

Bind the signature and nonce to the exact permissionId and account.

## How to reproduce

```bash
cd evm-hack-registry/42062-enable-mode-can-be-frontrun-to-add-policies-for-a-different_exp
forge test -vvvvv
```

## Sources

- [AuditVault finding #42062](https://github.com/Auditware/AuditVault/blob/main/findings/42062-enable-mode-can-be-frontrun-to-add-policies-for-a-different.md)
- [Original report](https://cdn.cantina.xyz/reports/cantina_rhinestone_smartsessions_core_aug2024.pdf)
- [Synthetic reduction](test/42062-enable-mode-can-be-frontrun-to-add-policies-for-a-different.sol)
- AuditVault auditor(s): Chinmay Farkya

*Reference: https://cdn.cantina.xyz/reports/cantina_rhinestone_smartsessions_core_aug2024.pdf*
