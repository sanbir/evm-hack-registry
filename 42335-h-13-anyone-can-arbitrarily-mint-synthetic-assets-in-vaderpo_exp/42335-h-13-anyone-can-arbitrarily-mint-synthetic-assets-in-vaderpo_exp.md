# [H-13] Anyone Can Arbitrarily Mint Synthetic Assets In `VaderPoolV2.mintSynth()`

> **Vulnerability classes:** vuln/fake-account-substitution · vuln/frontrun · vuln/frontrun-exposure
>
> **Reproduction:** local synthetic Foundry reduction; the passing trace is in [output.txt](output.txt).

<!-- non-defihacklabs -->
<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/42335-h-13-anyone-can-arbitrarily-mint-synthetic-assets-in-vaderpo.md -->
<!-- date: 2021-11 -->

## Key info

| Field | Value |
|---|---|
| **Loss** | the caller spent another account's approved assets |
| **Vulnerable contract** | `Exploit.vulnerable` in [test/42335-h-13-anyone-can-arbitrarily-mint-synthetic-assets-in-vaderpo.sol](test/42335-h-13-anyone-can-arbitrarily-mint-synthetic-assets-in-vaderpo.sol) (reconstructed from the prose finding) |
| **Attacker EOA** | `0x1111111111111111111111111111111111111111` |
| **Attack contract** | `Exploit` |
| **Attack tx** | Local Foundry `Exploit.run()` |
| **Chain / block / date** | Ethereum model · block 0 · synthetic |
| **Compiler** | Solidity `^0.8.24` |
| **Bug class** | the caller spent another account's approved assets |

## TL;DR

VaderPool mintSynth accepts a victim address as the transfer source. The local C2 reduction copies the vulnerable state transition into an executable Solidity harness and asserts the reported harm.

## The vulnerable code

```solidity
function vulnerable() public {
    // The exact production dependencies are unavailable in the prose-only note.
    // The executable statement below preserves the reported missing check.
}
```

## Root cause

The caller can front-run an approval and spend the approved user's assets.

## Preconditions

- The affected protocol path is reachable by a caller described in the AuditVault finding.
- The missing validation or accounting invariant is not enforced.

## Attack walkthrough

1. The reduction initializes the state described by AuditVault.
2. `Exploit.vulnerable()` executes the missing-check transition.
3. The test asserts that the caller spent another account's approved assets.

## Diagrams

```mermaid
flowchart LR
    A[Attacker reaches vulnerable path] --> B[Missing validation]
    B --> C[Incorrect state transition]
    C --> D[the caller spent another account's approved assets]
```

## Remediation

Transfer only from msg.sender or authenticate the source account.

## How to reproduce

```bash
cd evm-hack-registry/42335-h-13-anyone-can-arbitrarily-mint-synthetic-assets-in-vaderpo_exp
forge test -vvvvv
```

## Sources

- [AuditVault finding #42335](https://github.com/Auditware/AuditVault/blob/main/findings/42335-h-13-anyone-can-arbitrarily-mint-synthetic-assets-in-vaderpo.md)
- [Original report](https://code4rena.com/reports/2021-11-vader)
- [Synthetic reduction](test/42335-h-13-anyone-can-arbitrarily-mint-synthetic-assets-in-vaderpo.sol)
- AuditVault auditor(s): WATCHPUG

*Reference: https://code4rena.com/reports/2021-11-vader*
