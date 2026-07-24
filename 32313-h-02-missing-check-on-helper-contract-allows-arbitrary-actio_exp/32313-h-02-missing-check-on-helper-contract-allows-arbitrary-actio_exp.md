# Tapioca DAO — Unwhitelisted marketHelper returns malicious removeCollateral payload

> **Vulnerability classes:** missing-modifier, direct-drain, access-roles

> **Reproduction:** self-contained Foundry PoC (only `forge-std`) — no fork, no RPC.
> Full trace: [output.txt](output.txt). PoC: [test/32313-h-02-missing-check-on-helper-contract-allows-arbitrary-actio_exp.sol](test/32313-h-02-missing-check-on-helper-contract-allows-arbitrary-actio_exp.sol).

<!-- non-defihacklabs -->
<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/32313-h-02-missing-check-on-helper-contract-allows-arbitrary-actio.md -->
<!-- date: 2024-02 -->

---

## Key info

| | |
|---|---|
| **Impact** | **HIGH** — Malicious marketHelper steals victim collateral via Magnetar approval |
| **Protocol** | Tapioca DAO |
| **Vulnerable code** | `MagnetarOptionModule` (see `@>` in synthetic) |
| **Finding** | Code4rena · #32313 |
| **Report** | [https://code4rena.com/reports/2024-02-tapioca](https://code4rena.com/reports/2024-02-tapioca) |
| **Source** | [AuditVault](https://github.com/Auditware/AuditVault/blob/main/findings/32313-h-02-missing-check-on-helper-contract-allows-arbitrary-actio.md) |
| **Status** | Audit finding — reproduced as a standalone local PoC |
| **Compiler** | `^0.8.24` |

---

## TL;DR

Unwhitelisted marketHelper returns malicious removeCollateral payload. Harm demonstrated: **Malicious marketHelper steals victim collateral via Magnetar approval**.

---

## The vulnerable code

See `test/32313-h-02-missing-check-on-helper-contract-allows-arbitrary-actio.sol` — the blamed line is marked `// @> VULN`.

---

## Root cause

See the synthetic header comment and the AuditVault finding for the full root-cause write-up. The Playground preserves the vulnerable line verbatim and asserts the concrete harm in `Exploit.run()`.

## Attack walkthrough

1. Deploy the reduced vulnerable system (CREATE order: Cluster, BigBang, MagnetarOptionModule, MaliciousMarketHelper).
2. Seed the preconditions from the finding (approvals, balances, whitelist).
3. Execute the attack path; the `@>` line runs.
4. `require(...)` asserts the harm.

## Diagrams

```mermaid
flowchart TD
    A["Attacker / user drives entrypoint"] --> B["Vulnerable contract path"]
    B --> C["@> VULN line executes"]
    C --> D["Harm: Malicious marketHelper steals victim collateral via Magnetar"]
```

## Impact

Malicious marketHelper steals victim collateral via Magnetar approval

## Taxonomy

- missing-modifier, direct-drain, access-roles

## Sources

- [AuditVault finding](https://github.com/Auditware/AuditVault/blob/main/findings/32313-h-02-missing-check-on-helper-contract-allows-arbitrary-actio.md)
- [Code4rena report](https://code4rena.com/reports/2024-02-tapioca)
- Reduced from: `Tapioca-DAO/tapioca-periph MagnetarOptionModule.exitPositionAndRemoveCollateral`
