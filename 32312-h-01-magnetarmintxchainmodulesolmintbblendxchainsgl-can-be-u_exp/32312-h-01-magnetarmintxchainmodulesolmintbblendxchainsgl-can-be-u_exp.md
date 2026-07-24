# Tapioca DAO — mintBBLendXChainSGL compose data.user not bound — force-lend victim

> **Vulnerability classes:** missing-modifier, direct-drain, account-ownership

> **Reproduction:** self-contained Foundry PoC (only `forge-std`) — no fork, no RPC.
> Full trace: [output.txt](output.txt). PoC: [test/32312-h-01-magnetarmintxchainmodulesolmintbblendxchainsgl-can-be-u_exp.sol](test/32312-h-01-magnetarmintxchainmodulesolmintbblendxchainsgl-can-be-u_exp.sol).

<!-- non-defihacklabs -->
<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/32312-h-01-magnetarmintxchainmodulesolmintbblendxchainsgl-can-be-u.md -->
<!-- date: 2024-02 -->

---

## Key info

| | |
|---|---|
| **Impact** | **HIGH** — Whitelisted USDO compose forces lend of victim tokens into Magnetar |
| **Protocol** | Tapioca DAO |
| **Vulnerable code** | `MagnetarMintXChainModule` (see `@>` in synthetic) |
| **Finding** | Code4rena · #32312 |
| **Report** | [https://code4rena.com/reports/2024-02-tapioca](https://code4rena.com/reports/2024-02-tapioca) |
| **Source** | [AuditVault](https://github.com/Auditware/AuditVault/blob/main/findings/32312-h-01-magnetarmintxchainmodulesolmintbblendxchainsgl-can-be-u.md) |
| **Status** | Audit finding — reproduced as a standalone local PoC |
| **Compiler** | `^0.8.24` |

---

## TL;DR

mintBBLendXChainSGL compose data.user not bound — force-lend victim. Harm demonstrated: **Whitelisted USDO compose forces lend of victim tokens into Magnetar**.

---

## The vulnerable code

See `test/32312-h-01-magnetarmintxchainmodulesolmintbblendxchainsgl-can-be-u.sol` — the blamed line is marked `// @> VULN`.

---

## Root cause

See the synthetic header comment and the AuditVault finding for the full root-cause write-up. The Playground preserves the vulnerable line verbatim and asserts the concrete harm in `Exploit.run()`.

## Attack walkthrough

1. Deploy the reduced vulnerable system (CREATE order: Cluster, MockERC20, MagnetarAssetXChainModule, USDO, MagnetarMintXChainModule).
2. Seed the preconditions from the finding (approvals, balances, whitelist).
3. Execute the attack path; the `@>` line runs.
4. `require(...)` asserts the harm.

## Diagrams

```mermaid
flowchart TD
    A["Attacker / user drives entrypoint"] --> B["Vulnerable contract path"]
    B --> C["@> VULN line executes"]
    C --> D["Harm: Whitelisted USDO compose forces lend of victim tokens into M"]
```

## Impact

Whitelisted USDO compose forces lend of victim tokens into Magnetar

## Taxonomy

- missing-modifier, direct-drain, account-ownership

## Sources

- [AuditVault finding](https://github.com/Auditware/AuditVault/blob/main/findings/32312-h-01-magnetarmintxchainmodulesolmintbblendxchainsgl-can-be-u.md)
- [Code4rena report](https://code4rena.com/reports/2024-02-tapioca)
- Reduced from: `Tapioca-DAO/tapioca-periph MagnetarMintXChainModule.mintBBLendXChainSGL`
