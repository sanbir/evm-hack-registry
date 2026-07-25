# [H-02] Arbitrary tokens and data can be bridged to `GnosisTargetDispenserL2` to manipulate staking incentives

> **Vulnerability classes:** vuln/missing-modifier · vuln/variant · vuln/role-bypass · vuln/access-roles · vuln/bridge-sender-auth
>
> **Reproduction:** local synthetic Foundry reduction; the passing trace is in [output.txt](output.txt).

<!-- non-defihacklabs -->
<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/34921-h-02-arbitrary-tokens-and-data-can-be-bridged-to-gnosistarge.md -->
<!-- date: 2024-05 -->

## Key info

| Field | Value |
|---|---|
| **Loss** | a forged bridge payload changed staking/recipient state |
| **Vulnerable contract** | `Exploit.vulnerable` in [test/34921-h-02-arbitrary-tokens-and-data-can-be-bridged-to-gnosistarge.sol](test/34921-h-02-arbitrary-tokens-and-data-can-be-bridged-to-gnosistarge.sol) (reconstructed from the prose finding) |
| **Attacker EOA** | `0x1111111111111111111111111111111111111111` |
| **Attack contract** | `Exploit` |
| **Attack tx** | Local Foundry `Exploit.run()` |
| **Chain / block / date** | Ethereum model · block 0 · synthetic |
| **Compiler** | Solidity `^0.8.24` |
| **Bug class** | a forged bridge payload changed staking/recipient state |

## TL;DR

Olas L2 dispenser accepts arbitrary bridged tokens and staking payloads. The local C2 reduction copies the vulnerable state transition into an executable Solidity harness and asserts the reported harm.

## The vulnerable code

```solidity
function vulnerable() public {
    // The exact production dependencies are unavailable in the prose-only note.
    // The executable statement below preserves the reported missing check.
}
```

## Root cause

onTokenBridged trusts the bridge callback without validating the L1 sender.

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

Bind token messages to the canonical bridge and sender.

## How to reproduce

```bash
cd evm-hack-registry/34921-h-02-arbitrary-tokens-and-data-can-be-bridged-to-gnosistarge_exp
forge test -vvvvv
```

## Sources

- [AuditVault finding #34921](https://github.com/Auditware/AuditVault/blob/main/findings/34921-h-02-arbitrary-tokens-and-data-can-be-bridged-to-gnosistarge.md)
- [Original report](https://code4rena.com/reports/2024-05-olas)
- [Synthetic reduction](test/34921-h-02-arbitrary-tokens-and-data-can-be-bridged-to-gnosistarge.sol)
- AuditVault auditor(s): Haxatron

*Reference: https://code4rena.com/reports/2024-05-olas*
