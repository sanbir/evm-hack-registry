# Oku cancelled order can be modified and refunded twice

This POC executes the historical Oku `StopLimit`/order implementation vendored under `src/oku/`. It cancels an order, modifies it, and follows the real refund path to demonstrate the duplicate withdrawal.

```bash
forge test -vvv
```

Sources: [Sherlock Oku report](https://github.com/sherlock-audit/2024-11-oku-judging), [AuditVault finding #44374](https://github.com/Auditware/AuditVault/blob/main/findings/44374-h-4-users-can-modify-a-cancelled-order-withdrawing-the-same.md).
