# Rubicon — Precision loss makes openPosition leverage higher than expected

> **Vulnerability classes:** precision-loss · integer-bounds · liquidation-underwater

> **Reproduction:** self-contained Foundry PoC with **only `forge-std`** — no fork, no RPC.
> Full trace: [output.txt](output.txt). PoC:
> [test/48955-h-16-due-to-the-loss-of-precision-openposition-will-make-the_exp.sol](test/48955-h-16-due-to-the-loss-of-precision-openposition-will-make-the_exp.sol).

<!-- non-defihacklabs -->
<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/48955-h-16-due-to-the-loss-of-precision-openposition-will-make-the.md -->
<!-- date: 2023-04 -->

---

## Key info

| | |
|---|---|
| **Impact** | **HIGH** — leverage=1e18+1 floors desired to initMargin; lastBorrow=0 triggers 100% CF borrow (~1.7x) |
| **Protocol** | [Rubicon](https://rubicon.finance) |
| **Bug class** | precision-loss · integer-bounds · liquidation-underwater |
| **Finding** | Code4rena 2023-04-rubicon · #48955 · H-16 · reporter **cccz** |
| **Report** | [code4rena.com/reports/2023-04-rubicon](https://code4rena.com/reports/2023-04-rubicon) |
| **Source** | [AuditVault](https://github.com/Auditware/AuditVault/blob/main/findings/48955-h-16-due-to-the-loss-of-precision-openposition-will-make-the.md) |
| **Status** | Confirmed. Reproduced as a standalone local synthetic. |
| **Compiler** | `^0.8.24` (PoC) |

---

## TL;DR

wmul floor makes desired==init; lastBorrow=0 is treated as full borrow instead of zero extra leverage.

---

## The vulnerable code

See synthetic `test/48955-h-16-due-to-the-loss-of-precision-openposition-will-make-the.sol` (`@> VULN` markers).

**Fix:** Treat lastBorrow==0 with no excess as zero borrow; tighten leverage precision.

---

## Root cause

wmul floor makes desired==init; lastBorrow=0 is treated as full borrow instead of zero extra leverage.

---

## Preconditions

Protocol deployed with the vulnerable code paths from the Code4rena contest.

---

## Attack walkthrough

See PoC `run()` and [output.txt](output.txt).

---

## Diagrams

```mermaid
sequenceDiagram
    participant User
    participant Protocol
    User->>Protocol: trigger vulnerable path
    Protocol->>Protocol: hit @> VULN line
    Protocol-->>User: harm realized
```

---

## Impact

leverage=1e18+1 floors desired to initMargin; lastBorrow=0 triggers 100% CF borrow (~1.7x)

---

## Taxonomy

- `genome: precision-loss · integer-bounds · liquidation-underwater`
- `severity/high` · `platform/code4rena`

---

## Sources

- [AuditVault finding #48955](https://github.com/Auditware/AuditVault/blob/main/findings/48955-h-16-due-to-the-loss-of-precision-openposition-will-make-the.md)
- [Code4rena report 2023-04-rubicon](https://code4rena.com/reports/2023-04-rubicon)
- Repo@commit: [code-423n4/2023-04-rubicon](https://github.com/code-423n4/2023-04-rubicon) · contracts/utilities/poolsUtility/Position.sol _borrowLimit / openPosition
