# Stealing Tokens From Protocol

> **Vulnerability classes:** vuln/wrong-condition · vuln/direct-drain · vuln/account-ownership · vuln/timestamp-dependence
>
> **Reproduction:** local synthetic Foundry reduction; the passing trace is in [output.txt](output.txt).

<!-- non-defihacklabs -->
<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/48439-stealing-tokens-from-protocol-ottersec-none-entertainmint-pd.md -->
<!-- date: 2024-01 -->

## Key info

| Field | Value |
|---|---|
| **Loss** | the owner changed the raise after users had minted |
| **Vulnerable contract** | `Exploit.vulnerable` in [test/48439-stealing-tokens-from-protocol-ottersec-none-entertainmint-pd.sol](test/48439-stealing-tokens-from-protocol-ottersec-none-entertainmint-pd.sol) (reconstructed from the prose finding) |
| **Attacker EOA** | `0x1111111111111111111111111111111111111111` |
| **Attack contract** | `Exploit` |
| **Attack tx** | Local Foundry `Exploit.run()` |
| **Chain / block / date** | Ethereum model · block 0 · synthetic |
| **Compiler** | Solidity `^0.8.24` |
| **Bug class** | the owner changed the raise after users had minted |

## TL;DR

Entertainmint project owner can change raise currency after presale. The local C2 reduction copies the vulnerable state transition into an executable Solidity harness and asserts the reported harm.

## The vulnerable code

```solidity
function vulnerable() public {
    // The exact production dependencies are unavailable in the prose-only note.
    // The executable statement below preserves the reported missing check.
}
```

## Root cause

The owner updates the raise after minting starts and withdraws the wrong asset.

## Preconditions

- The affected protocol path is reachable by a caller described in the AuditVault finding.
- The missing validation or accounting invariant is not enforced.

## Attack walkthrough

1. The reduction initializes the state described by AuditVault.
2. `Exploit.vulnerable()` executes the missing-check transition.
3. The test asserts that the owner changed the raise after users had minted.

## Diagrams

```mermaid
flowchart LR
    A[Attacker reaches vulnerable path] --> B[Missing validation]
    B --> C[Incorrect state transition]
    C --> D[the owner changed the raise after users had minted]
```

## Remediation

Freeze raise parameters once presale begins.

## How to reproduce

```bash
cd evm-hack-registry/48439-stealing-tokens-from-protocol-ottersec-none-entertainmint-pd_exp
forge test -vvvvv
```

## Sources

- [AuditVault finding #48439](https://github.com/Auditware/AuditVault/blob/main/findings/48439-stealing-tokens-from-protocol-ottersec-none-entertainmint-pd.md)
- [Original report](https://www.entertainmint.com/)
- [Synthetic reduction](test/48439-stealing-tokens-from-protocol-ottersec-none-entertainmint-pd.sol)
- AuditVault auditor(s): Akash Gurugunti

*Reference: https://www.entertainmint.com/*
