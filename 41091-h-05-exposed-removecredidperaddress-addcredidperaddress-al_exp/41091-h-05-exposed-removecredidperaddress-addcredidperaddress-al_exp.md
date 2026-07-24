# Phi — Exposed public _add/_removeCredIdPerAddress bricks victim sells

> **Vulnerability classes:** vuln/access-control/missing-visibility · vuln/dos/state-corruption

> **Reproduction:** a self-contained Foundry PoC that compiles & runs in an
> isolated project with **only `forge-std`** — no fork, no RPC, no `anvil_state`.
> Full trace: [output.txt](output.txt). PoC:
> [test/41091-h-05-exposed-removecredidperaddress-addcredidperaddress-al_exp.sol](test/41091-h-05-exposed-removecredidperaddress-addcredidperaddress-al_exp.sol).

<!-- non-defihacklabs -->
<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/41091-h-05-exposed-removecredidperaddress-addcredidperaddress-al.md -->
<!-- date: 2024-08 -->

**AuditVault taxonomy:** `lang/solidity` · `sector/nft` · `platform/code4rena` · `severity/high` · genome: `frozen-funds` · `permanent` · `dos-resistance`

---

## Key info

| | |
|---|---|
| **Impact** | **HIGH** — Public _removeCredIdPerAddress lets anyone strip a victim's credId list so their subsequent sell reverts and shares are frozen |
| **Protocol** | Phi |
| **Finding** | Code4rena — Phi, 2024-08 · #41091 |
| **Report** | [2024-08-phi](https://code4rena.com/reports/2024-08-phi) |
| **Source** | [AuditVault](https://github.com/Auditware/AuditVault/blob/main/findings/41091-h-05-exposed-removecredidperaddress-addcredidperaddress-al.md) |
| **Status** | Audit finding — reproduced as a standalone local synthetic PoC. |
| **Compiler** | `^0.8.24` (PoC) |

---

## TL;DR

Public _removeCredIdPerAddress lets anyone strip a victim's credId list so their subsequent sell reverts and shares are frozen

See the vulnerable line marked `// @> VULN` in `test/41091-h-05-exposed-removecredidperaddress-addcredidperaddress-al.sol` and the
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

Public _removeCredIdPerAddress lets anyone strip a victim's credId list so their subsequent sell reverts and shares are frozen

---

## Sources

- [AuditVault finding](https://github.com/Auditware/AuditVault/blob/main/findings/41091-h-05-exposed-removecredidperaddress-addcredidperaddress-al.md)
- [Code4rena report](https://code4rena.com/reports/2024-08-phi)
- Reduced source: synthetic reconstruction of the blamed functions from the contest repo (see finding for verbatim snippets).
