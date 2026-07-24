# Streaming — recoverTokens broken after creatorClaimSoldTokens (isSale)

> **Vulnerability classes:** vuln/accounting/missing-state-update · vuln/loss-of-funds/locked-funds

> **Reproduction:** a self-contained Foundry PoC that compiles & runs in an
> isolated project with **only `forge-std`** — no fork, no RPC, no `anvil_state`.
> Full trace: [output.txt](output.txt). PoC:
> [test/42396-h-10-recovertokens-doesnt-work-when-issale-is-true-code4rena_exp.sol](test/42396-h-10-recovertokens-doesnt-work-when-issale-is-true-code4rena_exp.sol).

<!-- non-defihacklabs -->
<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/42396-h-10-recovertokens-doesnt-work-when-issale-is-true-code4rena.md -->
<!-- date: 2021-11 -->

**AuditVault taxonomy:** `lang/solidity` · `sector/token` · `platform/code4rena` · `severity/high` · genome: `wrong-condition` · `locked-funds`

---

## Key info

| | |
|---|---|
| **Impact** | **HIGH** — creatorClaimSoldTokens does not update redeemedDepositTokens, so recoverTokens underflows and excess deposit tokens are permanently locked |
| **Protocol** | Streaming Protocol |
| **Finding** | Code4rena — Streaming Protocol, 2021-11 · #42396 |
| **Report** | [2021-11-streaming](https://code4rena.com/reports/2021-11-streaming) |
| **Source** | [AuditVault](https://github.com/Auditware/AuditVault/blob/main/findings/42396-h-10-recovertokens-doesnt-work-when-issale-is-true-code4rena.md) |
| **Status** | Audit finding — reproduced as a standalone local synthetic PoC. |
| **Compiler** | `^0.8.24` (PoC) |

---

## TL;DR

creatorClaimSoldTokens does not update redeemedDepositTokens, so recoverTokens underflows and excess deposit tokens are permanently locked

See the vulnerable line marked `// @> VULN` in `test/42396-h-10-recovertokens-doesnt-work-when-issale-is-true-code4rena.sol` and the
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

creatorClaimSoldTokens does not update redeemedDepositTokens, so recoverTokens underflows and excess deposit tokens are permanently locked

---

## Sources

- [AuditVault finding](https://github.com/Auditware/AuditVault/blob/main/findings/42396-h-10-recovertokens-doesnt-work-when-issale-is-true-code4rena.md)
- [Code4rena report](https://code4rena.com/reports/2021-11-streaming)
- Reduced source: synthetic reconstruction of the blamed functions from the contest repo (see finding for verbatim snippets).
