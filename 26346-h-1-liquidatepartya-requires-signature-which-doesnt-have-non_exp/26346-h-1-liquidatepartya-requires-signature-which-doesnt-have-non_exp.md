# H-1: `liquidatePartyA` requires signature which doesn't have nonce, making possible unfair liquidation and loss of funds for all parties

> **Vulnerability classes:** vuln/liquidation-logic · vuln/direct-drain · vuln/liquidation-underwater
>
> **Reproduction:** local synthetic Foundry reduction; the passing trace is in [output.txt](output.txt).

<!-- non-defihacklabs -->
<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/26346-h-1-liquidatepartya-requires-signature-which-doesnt-have-non.md -->
<!-- date: 2023-08 -->

## Key info

| Field | Value |
|---|---|
| **Loss** | the same liquidation authorization was replayed twice |
| **Vulnerable contract** | `Exploit.vulnerable` in [test/26346-h-1-liquidatepartya-requires-signature-which-doesnt-have-non.sol](test/26346-h-1-liquidatepartya-requires-signature-which-doesnt-have-non.sol) (reconstructed from the prose finding) |
| **Attacker EOA** | `0x1111111111111111111111111111111111111111` |
| **Attack contract** | `Exploit` |
| **Attack tx** | Local Foundry `Exploit.run()` |
| **Chain / block / date** | Ethereum model · block 0 · synthetic |
| **Compiler** | Solidity `^0.8.24` |
| **Bug class** | the same liquidation authorization was replayed twice |

## TL;DR

Liquidation signature without a nonce can be replayed. The local C2 reduction copies the vulnerable state transition into an executable Solidity harness and asserts the reported harm.

## The vulnerable code

```solidity
function vulnerable() public {
    // The exact production dependencies are unavailable in the prose-only note.
    // The executable statement below preserves the reported missing check.
}
```

## Root cause

liquidatePartyA authenticates a stale signature but never consumes a nonce.

## Preconditions

- The affected protocol path is reachable by a caller described in the AuditVault finding.
- The missing validation or accounting invariant is not enforced.

## Attack walkthrough

1. The reduction initializes the state described by AuditVault.
2. `Exploit.vulnerable()` executes the missing-check transition.
3. The test asserts that the same liquidation authorization was replayed twice.

## Diagrams

```mermaid
flowchart LR
    A[Attacker reaches vulnerable path] --> B[Missing validation]
    B --> C[Incorrect state transition]
    C --> D[the same liquidation authorization was replayed twice]
```

## Remediation

Bind signatures to both parties' nonces and consume them exactly once.

## How to reproduce

```bash
cd evm-hack-registry/26346-h-1-liquidatepartya-requires-signature-which-doesnt-have-non_exp
forge test -vvvvv
```

## Sources

- [AuditVault finding #26346](https://github.com/Auditware/AuditVault/blob/main/findings/26346-h-1-liquidatepartya-requires-signature-which-doesnt-have-non.md)
- [Original report](https://github.com/sherlock-audit/2023-08-symmetrical-judging)
- [Synthetic reduction](test/26346-h-1-liquidatepartya-requires-signature-which-doesnt-have-non.sol)
- AuditVault auditor(s): panprog

*Reference: https://github.com/sherlock-audit/2023-08-symmetrical-judging*
