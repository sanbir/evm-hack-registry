# Maia DAO — checkParams does not check token is underlying of hToken

> **Vulnerability classes:** see taxonomy below

> **Reproduction:** a self-contained Foundry PoC that compiles & runs in an
> isolated project with **only `forge-std`** — no fork, no RPC, no `anvil_state`.
> Full trace: [output.txt](output.txt). PoC:
> [test/26043-h-09-rootbridgeagent-checkparamslibcheckparams-does-not-chec_exp.sol](test/26043-h-09-rootbridgeagent-checkparamslibcheckparams-does-not-chec_exp.sol).

<!-- non-defihacklabs -->
<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/26043-h-09-rootbridgeagent-checkparamslibcheckparams-does-not-chec.md -->
<!-- date: 2023-05 -->

---

## Key info

| | |
|---|---|
| **Impact** | **HIGH** — Deposit 10 USDC, mint 10 global hEther (mismatched pair) — fund theft |
| **Protocol** | Maia DAO |
| **Finding** | Code4rena · reporter **xuwinnie** |
| **Report** | [https://code4rena.com/reports/2023-05-maia](https://code4rena.com/reports/2023-05-maia) |
| **Source** | [AuditVault](https://github.com/Auditware/AuditVault/blob/main/findings/26043-h-09-rootbridgeagent-checkparamslibcheckparams-does-not-chec.md) |
| **Status** | Audit finding — reproduced as a standalone local PoC. |
| **Compiler** | `^0.8.24` (PoC) |

This is an **audit finding**, not a historical on-chain incident.

---

## TL;DR

1. checkParams requires underlying exists and hToken is local, not that they pair.\n2. Attacker deposits USDC with hToken=hEther.\n3. Root mints 10 global hEther for 10 USDC.

## Diagrams

```mermaid
flowchart TD
    A[Setup vulnerable state] --> B[Trigger vulnerable path]
    B --> C[Harm asserted in run]
```

## Impact

Deposit 10 USDC, mint 10 global hEther (mismatched pair) — fund theft

## Sources

- [AuditVault finding](https://github.com/Auditware/AuditVault/blob/main/findings/26043-h-09-rootbridgeagent-checkparamslibcheckparams-does-not-chec.md)
- [Code4rena report](https://code4rena.com/reports/2023-05-maia)
- Reduced synthetic: `test/26043-h-09-rootbridgeagent-checkparamslibcheckparams-does-not-chec.sol` (C2 local-deploy)
