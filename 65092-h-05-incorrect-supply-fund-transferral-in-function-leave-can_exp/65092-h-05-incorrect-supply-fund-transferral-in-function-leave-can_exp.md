# Recall — [H-05] Incorrect supply fund transferral in leave()

> **Vulnerability classes:** severity/high · platform/code4rena · sector/staking · sector/governance
>
> **Reproduction:** self-contained Foundry PoC with only `forge-std` — no fork, no RPC.
> Full trace: [output.txt](output.txt).

<!-- non-defihacklabs -->
<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/65092-h-05-incorrect-supply-fund-transferral-in-function-leave-can.md -->
<!-- date: 2025-02 -->

**AuditVault taxonomy:** `lang/solidity` · `platform/code4rena` · `has/poc` · `severity/high` · protocol Recall

---

## Key info

| | |
|---|---|
| **Impact** | **HIGH** — leave() pays genesisBalance as ETH collateral instead of supply ERC20 — drains other validators |
| **Protocol** | [Recall](https://code4rena.com/reports/2025-02-recall) (IPC / subnet actor) |
| **Finding** | Code4rena 2025-02-recall · #65092 |
| **Report** | [2025-02-recall](https://code4rena.com/reports/2025-02-recall) |
| **Source** | [AuditVault](https://github.com/Auditware/AuditVault/blob/main/findings/65092-h-05-incorrect-supply-fund-transferral-in-function-leave-can.md) |
| **Compiler** | `^0.8.24` (PoC) |

---

## TL;DR

leave() pays genesisBalance as ETH collateral instead of supply ERC20 — drains other validators

---

## The vulnerable code

```solidity
collateralSource.transferFunds(payable(msg.sender), genesisBal); // @> VULN
```

**Fix:** Use supplySource.transferFunds for genesis refunds (as preRelease does).

---

## Root cause

See vulnerable line above. Reduced synthetic preserves the blamed statement verbatim (`@> VULN`).

---

## Preconditions

- Audited Recall / IPC contracts at contest commit `ab5f90b9`.
- Attack path as described in the Code4rena report.

---

## Attack walkthrough

1. Deploy the synthetic vulnerable surface.
2. Execute the attack in `Exploit.run()`.
3. Assert the report's concrete harm (funds / liveness / forged consensus).

---

## Diagrams

```mermaid
flowchart TD
    A["Attacker crafts inputs"] --> B["Vulnerable function executes"]
    B --> C{"Bug condition?"}
    C -- "yes" --> D["HARM: leave() pays genesisBalance as ETH collateral instead of supply ERC20 — drains other validators"]
    C -- "no" --> E["Would be safe if fixed"]
```

```mermaid
sequenceDiagram
    participant A as Attacker
    participant V as Vulnerable
    participant S as State
    A->>V: trigger
    V->>S: bad update
    Note over V: @> VULN line
    S-->>A: harm realized
```

## Remediation

Use supplySource.transferFunds for genesis refunds (as preRelease does).

---

## Sources

- [AuditVault finding](https://github.com/Auditware/AuditVault/blob/main/findings/65092-h-05-incorrect-supply-fund-transferral-in-function-leave-can.md)
- [Code4rena report 2025-02-recall](https://code4rena.com/reports/2025-02-recall)
- Reduced source: [code-423n4/2025-02-recall@ab5f90b9](https://github.com/code-423n4/2025-02-recall/tree/ab5f90b9b0322016ecce6dd71c528a935544bec5)
