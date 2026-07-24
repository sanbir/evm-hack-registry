# Tapioca DAO — Magnetar grants YieldBox approval but markets only accept pearlmit

> **Vulnerability classes:** wrong-condition, permanent, access-roles

> **Reproduction:** self-contained Foundry PoC (only `forge-std`) — no fork, no RPC.
> Full trace: [output.txt](output.txt). PoC: [test/32315-h-04-incorrect-approval-mechanism-breaks-all-magnetar-functi_exp.sol](test/32315-h-04-incorrect-approval-mechanism-breaks-all-magnetar-functi_exp.sol).

<!-- non-defihacklabs -->
<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/32315-h-04-incorrect-approval-mechanism-breaks-all-magnetar-functi.md -->
<!-- date: 2024-02 -->

---

## Key info

| | |
|---|---|
| **Impact** | **HIGH** — Magnetar deposit/lend permanently fails — wrong approval mechanism vs pearlmit |
| **Protocol** | Tapioca DAO |
| **Vulnerable code** | `Magnetar` (see `@>` in synthetic) |
| **Finding** | Code4rena · #32315 |
| **Report** | [https://code4rena.com/reports/2024-02-tapioca](https://code4rena.com/reports/2024-02-tapioca) |
| **Source** | [AuditVault](https://github.com/Auditware/AuditVault/blob/main/findings/32315-h-04-incorrect-approval-mechanism-breaks-all-magnetar-functi.md) |
| **Status** | Audit finding — reproduced as a standalone local PoC |
| **Compiler** | `^0.8.24` |

---

## TL;DR

Magnetar grants YieldBox approval but markets only accept pearlmit. Harm demonstrated: **Magnetar deposit/lend permanently fails — wrong approval mechanism vs pearlmit**.

---

## The vulnerable code

See `test/32315-h-04-incorrect-approval-mechanism-breaks-all-magnetar-functi.sol` — the blamed line is marked `// @> VULN`.

---

## Root cause

See the synthetic header comment and the AuditVault finding for the full root-cause write-up. The Playground preserves the vulnerable line verbatim and asserts the concrete harm in `Exploit.run()`.

## Attack walkthrough

1. Deploy the reduced vulnerable system (CREATE order: MockERC20, MockYieldBox, Pearlmit, Singularity, Magnetar).
2. Seed the preconditions from the finding (approvals, balances, whitelist).
3. Execute the attack path; the `@>` line runs.
4. `require(...)` asserts the harm.

## Diagrams

```mermaid
flowchart TD
    A["Attacker / user drives entrypoint"] --> B["Vulnerable contract path"]
    B --> C["@> VULN line executes"]
    C --> D["Harm: Magnetar deposit/lend permanently fails — wrong approval mec"]
```

## Impact

Magnetar deposit/lend permanently fails — wrong approval mechanism vs pearlmit

## Taxonomy

- wrong-condition, permanent, access-roles

## Sources

- [AuditVault finding](https://github.com/Auditware/AuditVault/blob/main/findings/32315-h-04-incorrect-approval-mechanism-breaks-all-magnetar-functi.md)
- [Code4rena report](https://code4rena.com/reports/2024-02-tapioca)
- Reduced from: `Tapioca-DAO/tapioca-periph MagnetarAssetCommonModule._depositYBLendSGL`
