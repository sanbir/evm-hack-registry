# Maia DAO — TalosBaseStrategy#init() lacks slippage protection

> **Vulnerability classes:** see taxonomy below

> **Reproduction:** a self-contained Foundry PoC that compiles & runs in an
> isolated project with **only `forge-std`** — no fork, no RPC, no `anvil_state`.
> Full trace: [output.txt](output.txt). PoC:
> [test/26044-h-10-talosbasestrategyinit-lacks-slippage-protection-code4re_exp.sol](test/26044-h-10-talosbasestrategyinit-lacks-slippage-protection-code4re_exp.sol).

<!-- non-defihacklabs -->
<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/26044-h-10-talosbasestrategyinit-lacks-slippage-protection-code4re.md -->
<!-- date: 2023-05 -->

---

## Key info

| | |
|---|---|
| **Impact** | **HIGH** — init hardcodes amount0Min/1Min=0 and skips checkDeviation; sandwich extracts 99+99 of 100+100 deposit |
| **Protocol** | Maia DAO |
| **Finding** | Code4rena · reporter **los_chicos** |
| **Report** | [https://code4rena.com/reports/2023-05-maia](https://code4rena.com/reports/2023-05-maia) |
| **Source** | [AuditVault](https://github.com/Auditware/AuditVault/blob/main/findings/26044-h-10-talosbasestrategyinit-lacks-slippage-protection-code4re.md) |
| **Status** | Audit finding — reproduced as a standalone local PoC. |
| **Compiler** | `^0.8.24` (PoC) |

This is an **audit finding**, not a historical on-chain incident.

---

## TL;DR

1. deposit() has checkDeviation; init() does not.\n2. amount0Min/amount1Min hardcoded to 0.\n3. Price manipulation drains 99% of init deposit.

## Diagrams

```mermaid
flowchart TD
    A[Setup vulnerable state] --> B[Trigger vulnerable path]
    B --> C[Harm asserted in run]
```

## Impact

init hardcodes amount0Min/1Min=0 and skips checkDeviation; sandwich extracts 99+99 of 100+100 deposit

## Sources

- [AuditVault finding](https://github.com/Auditware/AuditVault/blob/main/findings/26044-h-10-talosbasestrategyinit-lacks-slippage-protection-code4re.md)
- [Code4rena report](https://code4rena.com/reports/2023-05-maia)
- Reduced synthetic: `test/26044-h-10-talosbasestrategyinit-lacks-slippage-protection-code4re.sol` (C2 local-deploy)
