# Polynomial — Exchange._liquidate burns too much powerPerp

> **Vulnerability classes:** vuln/liquidation/over-burn · vuln/accounting/asymmetric-settlement

> **Reproduction:** a self-contained Foundry PoC that compiles & runs in an
> isolated project with **only `forge-std`** — no fork, no RPC, no `anvil_state`.
> Full trace: [output.txt](output.txt). PoC:
> [test/20224-h-01-exchange-liquidate-function-can-cause-liquidator-to-bur_exp.sol](test/20224-h-01-exchange-liquidate-function-can-cause-liquidator-to-bur_exp.sol).

<!-- non-defihacklabs -->
<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/20224-h-01-exchange-liquidate-function-can-cause-liquidator-to-bur.md -->
<!-- date: 2023-03 -->

**AuditVault taxonomy:** `lang/solidity` · `sector/lending` · `platform/code4rena` · `severity/high` · genome: `liquidation-logic` · `direct-drain`

---

## Key info

| | |
|---|---|
| **Impact** | **HIGH** — When ShortCollateral caps collateral returned on an underwater short, Exchange still burns the full debtRepaying of powerPerp from the liquidator |
| **Protocol** | Polynomial Protocol |
| **Finding** | Code4rena — Polynomial Protocol, 2023-03 · #20224 |
| **Report** | [2023-03-polynomial](https://code4rena.com/reports/2023-03-polynomial) |
| **Source** | [AuditVault](https://github.com/Auditware/AuditVault/blob/main/findings/20224-h-01-exchange-liquidate-function-can-cause-liquidator-to-bur.md) |
| **Status** | Audit finding — reproduced as a standalone local synthetic PoC. |
| **Compiler** | `^0.8.24` (PoC) |

---

## TL;DR

When ShortCollateral caps collateral returned on an underwater short, Exchange still burns the full debtRepaying of powerPerp from the liquidator

See the vulnerable line marked `// @> VULN` in `test/20224-h-01-exchange-liquidate-function-can-cause-liquidator-to-bur.sol` and the
end-to-end `Exploit.run()` that asserts the harm.

---

## Diagrams

```mermaid
flowchart TD
    A[Setup vulnerable state] --> B[Attacker triggers vulnerable path]
    B --> C["Vulnerable line executes @> VULN"]
    C --> D[Harm asserted in run]
```

---

## Impact

When ShortCollateral caps collateral returned on an underwater short, Exchange still burns the full debtRepaying of powerPerp from the liquidator

---

## Sources

- [AuditVault finding](https://github.com/Auditware/AuditVault/blob/main/findings/20224-h-01-exchange-liquidate-function-can-cause-liquidator-to-bur.md)
- [Code4rena report](https://code4rena.com/reports/2023-03-polynomial)
- Reduced source: synthetic reconstruction of the blamed functions from the contest repo (see finding for verbatim snippets).
