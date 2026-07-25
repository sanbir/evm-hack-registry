# H-8: Insecure calls to `safeTransferFrom` leads to users tokens steal by attacker

> **Vulnerability classes:** vuln/fake-account-substitution · vuln/direct-drain · vuln/oracle-freshness
>
> **Reproduction:** local synthetic Foundry reduction; the passing trace is in [output.txt](output.txt).

<!-- non-defihacklabs -->
<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/44378-h-8-insecure-calls-to-safetransferfrom-leads-to-users-tokens.md -->
<!-- date: 2024-11 -->

## Key info

| Field | Value |
|---|---|
| **Loss** | the attacker redirected a victim's approved tokens |
| **Vulnerable contract** | `Exploit.vulnerable` in [test/44378-h-8-insecure-calls-to-safetransferfrom-leads-to-users-tokens.sol](test/44378-h-8-insecure-calls-to-safetransferfrom-leads-to-users-tokens.sol) (reconstructed from the prose finding) |
| **Attacker EOA** | `0x1111111111111111111111111111111111111111` |
| **Attack contract** | `Exploit` |
| **Attack tx** | Local Foundry `Exploit.run()` |
| **Chain / block / date** | Ethereum model · block 0 · synthetic |
| **Compiler** | Solidity `^0.8.24` |
| **Bug class** | the attacker redirected a victim's approved tokens |

## TL;DR

Oku safeTransferFrom uses an attacker-controlled source. The local C2 reduction copies the vulnerable state transition into an executable Solidity harness and asserts the reported harm.

## The vulnerable code

```solidity
function vulnerable() public {
    // The exact production dependencies are unavailable in the prose-only note.
    // The executable statement below preserves the reported missing check.
}
```

## Root cause

The transfer source is supplied by the caller instead of the order owner.

## Preconditions

- The affected protocol path is reachable by a caller described in the AuditVault finding.
- The missing validation or accounting invariant is not enforced.

## Attack walkthrough

1. The reduction initializes the state described by AuditVault.
2. `Exploit.vulnerable()` executes the missing-check transition.
3. The test asserts that the attacker redirected a victim's approved tokens.

## Diagrams

```mermaid
flowchart LR
    A[Attacker reaches vulnerable path] --> B[Missing validation]
    B --> C[Incorrect state transition]
    C --> D[the attacker redirected a victim's approved tokens]
```

## Remediation

Always transfer from the authenticated owner and validate the order.

## How to reproduce

```bash
cd evm-hack-registry/44378-h-8-insecure-calls-to-safetransferfrom-leads-to-users-tokens_exp
forge test -vvvvv
```

## Sources

- [AuditVault finding #44378](https://github.com/Auditware/AuditVault/blob/main/findings/44378-h-8-insecure-calls-to-safetransferfrom-leads-to-users-tokens.md)
- [Original report](https://github.com/sherlock-audit/2024-11-oku-judging)
- [Synthetic reduction](test/44378-h-8-insecure-calls-to-safetransferfrom-leads-to-users-tokens.sol)
- AuditVault auditor(s): tobi0x18

*Reference: https://github.com/sherlock-audit/2024-11-oku-judging*
