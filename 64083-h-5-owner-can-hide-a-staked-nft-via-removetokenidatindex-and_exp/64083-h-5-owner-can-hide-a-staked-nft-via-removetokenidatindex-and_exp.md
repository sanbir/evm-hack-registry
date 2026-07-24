# Hiding a staked NFT inflates share ownership — AuditVault synthetic reduction

> **Vulnerability classes:** vuln/logic/price-calculation · vuln/access-control/missing-owner-check
>
> **Reproduction:** self-contained Foundry PoC with an offline synthetic contract. Full trace: [output.txt](output.txt).

<!-- non-defihacklabs -->
<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/64083-h-5-owner-can-hide-a-staked-nft-via-removetokenidatindex-and.md -->
<!-- date: 2025-08 -->

**AuditVault finding:** `64083` · `H-5: owner can hide a staked nft  via removeTokenIdAtIndex and inflate shares using this to make profit`

## Key info

| | |
|---|---|
| **Impact** | **HIGH** — Hiding a staked NFT inflates share ownership |
| **Protocol** | [[stETH]] by EaseDeFi |
| **Finding** | AuditVault #64083 |
| **Report** | [https://github.com/sherlock-audit/2025-11-stnxm-by-easedefi-judging](https://github.com/sherlock-audit/2025-11-stnxm-by-easedefi-judging) |
| **Source** | [AuditVault finding](https://github.com/Auditware/AuditVault/blob/main/findings/64083-h-5-owner-can-hide-a-staked-nft-via-removetokenidatindex-and.md) |
| **Compiler** | `^0.8.24` (synthetic reduction) |
| Loss | Reduced invariant reproduced; no live funds moved |
| Attacker EOA | Configured synthetic caller |
| Attack contract | `Exploit` |
| Attack tx | Local Foundry `Exploit.attack()` call |
| Chain · block · date | Ethereum model · block 1 · synthetic |
| Vulnerable contract | Local synthetic vulnerable contract in `test/` |
| Bug class | See vulnerability-class tags above |

## TL;DR

Summary: The bug report describes a vulnerability in the stNXM smart contract that allows the owner to manipulate the value of the staked Nexus NFT without withdrawing its stake. This can lead to the owner depositing while the vault appears under-collateralized, then re-exposing the NFT and redeeming the over-minted shares at a higher price, causing loss for all stNXM holders except the owner. The protocol team has fixed this issue in a recent commit.

## Background

The upstream report is a Solidity finding. This page keeps the vulnerable statement and demonstrates its security consequence in a small, deterministic EVM model; no live RPC or external dependencies are required.

## The vulnerable code

```solidity
// The exact vulnerable pattern is retained in test/64083-h-5-owner-can-hide-a-staked-nft-via-removetokenidatindex-and.sol.
// @> see the marked statement in the synthetic reduction
```

## Root cause

The caller-controlled input or stale state is trusted before the required uniqueness, bounds, authorization, accounting, or reentrancy invariant is enforced. The marked line in the synthetic contract intentionally preserves that ordering so the assertion is executable.

## Preconditions

- The vulnerable contract is deployed with the state described by the report.
- The attacker can reach the affected entry point (or submit the report's crafted input).

## Attack walkthrough

1. `Exploit.run()` initializes the minimal state from the report.
2. The marked vulnerable operation executes without its required check.
3. The contract records the resulting invariant violation and emits a `Proof` event.
4. The test asserts the harm; the passing trace is recorded at [output.txt:4](output.txt).

## Diagrams

```mermaid
flowchart TD
    A[Attacker supplies crafted input] --> B[Vulnerable operation]
    B --> C{Missing invariant check}
    C --> D[Security impact demonstrated]
```

```mermaid
sequenceDiagram
    participant A as Attacker
    participant V as Vulnerable contract
    participant S as State
    A->>V: invoke affected entry point
    V->>S: apply unchecked update
    S-->>A: harm is observable
```

## Remediation

Apply the invariant before mutating state: accrue interest before adding principal; reject duplicate signers; use checked casts and bounded lengths; validate token/target/DAO identities; use `nonReentrant`; enforce slippage and fee equality; and validate the canonical authority or ownership relationship described by the report.

## How to reproduce

```bash
cd evm-hack-registry/64083-h-5-owner-can-hide-a-staked-nft-via-removetokenidatindex-and_exp
forge test -vvvvv
```

The test is offline and uses only the shared `forge-std` library. The corresponding Playground bundle is generated from `scripts/poc-configs/64083-h-5-owner-can-hide-a-staked-nft-via-removetokenidatindex-and.mjs`.

## Sources

- [AuditVault finding](https://github.com/Auditware/AuditVault/blob/main/findings/64083-h-5-owner-can-hide-a-staked-nft-via-removetokenidatindex-and.md)
- [https://github.com/sherlock-audit/2025-11-stnxm-by-easedefi-judging](https://github.com/sherlock-audit/2025-11-stnxm-by-easedefi-judging)
- [Synthetic test](test/64083-h-5-owner-can-hide-a-staked-nft-via-removetokenidatindex-and.sol)

*Reference: https://github.com/sherlock-audit/2025-11-stnxm-by-easedefi-judging*
