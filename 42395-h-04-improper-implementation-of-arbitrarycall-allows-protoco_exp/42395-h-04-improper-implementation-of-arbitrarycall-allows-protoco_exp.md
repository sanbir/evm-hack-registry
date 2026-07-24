# Streaming — arbitraryCall lets compromised gov drain user allowances

> **Vulnerability classes:** vuln/access-control/dangerous-call · vuln/approval/leftover-allowance

> **Reproduction:** a self-contained Foundry PoC that compiles & runs in an
> isolated project with **only `forge-std`** — no fork, no RPC, no `anvil_state`.
> Full trace: [output.txt](output.txt). PoC:
> [test/42395-h-04-improper-implementation-of-arbitrarycall-allows-protoco_exp.sol](test/42395-h-04-improper-implementation-of-arbitrarycall-allows-protoco_exp.sol).

<!-- non-defihacklabs -->
<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/42395-h-04-improper-implementation-of-arbitrarycall-allows-protoco.md -->
<!-- date: 2021-11 -->

**AuditVault taxonomy:** `lang/solidity` · `sector/governance` · `platform/code4rena` · `severity/high` · genome: `missing-modifier` · `direct-drain` · `access-roles`

---

## Key info

| | |
|---|---|
| **Impact** | **HIGH** — After an incentive is claimed, incentives[token]==0 so compromised governance can arbitraryCall the token with transferFrom and steal leftover allowances |
| **Protocol** | Streaming Protocol |
| **Finding** | Code4rena — Streaming Protocol, 2021-11 · #42395 |
| **Report** | [2021-11-streaming](https://code4rena.com/reports/2021-11-streaming) |
| **Source** | [AuditVault](https://github.com/Auditware/AuditVault/blob/main/findings/42395-h-04-improper-implementation-of-arbitrarycall-allows-protoco.md) |
| **Status** | Audit finding — reproduced as a standalone local synthetic PoC. |
| **Compiler** | `^0.8.24` (PoC) |

---

## TL;DR

After an incentive is claimed, incentives[token]==0 so compromised governance can arbitraryCall the token with transferFrom and steal leftover allowances

See the vulnerable line marked `// @> VULN` in `test/42395-h-04-improper-implementation-of-arbitrarycall-allows-protoco.sol` and the
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

After an incentive is claimed, incentives[token]==0 so compromised governance can arbitraryCall the token with transferFrom and steal leftover allowances

---

## Sources

- [AuditVault finding](https://github.com/Auditware/AuditVault/blob/main/findings/42395-h-04-improper-implementation-of-arbitrarycall-allows-protoco.md)
- [Code4rena report](https://code4rena.com/reports/2021-11-streaming)
- Reduced source: synthetic reconstruction of the blamed functions from the contest repo (see finding for verbatim snippets).
