# Tapioca DAO — FakeBigBang steals Singularity assets via unwhitelisted Magnetar repay

> **Vulnerability classes:** fake-account-substitution, direct-drain, account-ownership

> **Reproduction:** self-contained Foundry PoC (only `forge-std`) — no fork, no RPC.
> Full trace: [output.txt](output.txt). PoC: [test/27537-h-47-users-assets-can-be-stolen-when-removing-them-from-the_exp.sol](test/27537-h-47-users-assets-can-be-stolen-when-removing-them-from-the_exp.sol).

<!-- non-defihacklabs -->
<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/27537-h-47-users-assets-can-be-stolen-when-removing-them-from-the.md -->
<!-- date: 2023-07 -->

---

## Key info

| | |
|---|---|
| **Impact** | **HIGH** — Victim Singularity assets drained to attacker via FakeBigBang YieldBox allowance |
| **Protocol** | Tapioca DAO |
| **Vulnerable code** | `Magnetar` (see `@>` in synthetic) |
| **Finding** | Code4rena · #27537 |
| **Report** | [https://code4rena.com/reports/2023-07-tapioca](https://code4rena.com/reports/2023-07-tapioca) |
| **Source** | [AuditVault](https://github.com/Auditware/AuditVault/blob/main/findings/27537-h-47-users-assets-can-be-stolen-when-removing-them-from-the.md) |
| **Status** | Audit finding — reproduced as a standalone local PoC |
| **Compiler** | `^0.8.24` |

---

## TL;DR

FakeBigBang steals Singularity assets via unwhitelisted Magnetar repay. Harm demonstrated: **Victim Singularity assets drained to attacker via FakeBigBang YieldBox allowance**.

---

## The vulnerable code

See `test/27537-h-47-users-assets-can-be-stolen-when-removing-them-from-the.sol` — the blamed line is marked `// @> VULN`.

---

## Root cause

See the synthetic header comment and the AuditVault finding for the full root-cause write-up. The Playground preserves the vulnerable line verbatim and asserts the concrete harm in `Exploit.run()`.

## Attack walkthrough

1. Deploy the reduced vulnerable system (CREATE order: MockYieldBox, Singularity, Magnetar, FakeBigBang).
2. Seed the preconditions from the finding (approvals, balances, whitelist).
3. Execute the attack path; the `@>` line runs.
4. `require(...)` asserts the harm.

## Diagrams

```mermaid
flowchart TD
    A["Attacker / user drives entrypoint"] --> B["Vulnerable contract path"]
    B --> C["@> VULN line executes"]
    C --> D["Harm: Victim Singularity assets drained to attacker via FakeBigBan"]
```

## Impact

Victim Singularity assets drained to attacker via FakeBigBang YieldBox allowance

## Taxonomy

- fake-account-substitution, direct-drain, account-ownership

## Sources

- [AuditVault finding](https://github.com/Auditware/AuditVault/blob/main/findings/27537-h-47-users-assets-can-be-stolen-when-removing-them-from-the.md)
- [Code4rena report](https://code4rena.com/reports/2023-07-tapioca)
- Reduced from: `Tapioca-DAO/tapioca-periph-audit MagnetarMarketModule remove+repay path`
