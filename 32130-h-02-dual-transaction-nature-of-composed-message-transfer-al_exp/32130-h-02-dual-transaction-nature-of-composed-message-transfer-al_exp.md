# Canto composed-message transfer front-run

This POC runs the historical Canto composed-message/transfer implementation vendored under `src/canto/`. It submits the two-step transfer sequence through the real message handler and demonstrates the recipient confusion described by the finding.

```bash
forge test -vvv
```

Sources: [AuditVault finding #32130](https://github.com/Auditware/AuditVault/blob/main/findings/32130-h-02-dual-transaction-nature-of-composed-message-transfer-al.md), [Canto repository](https://github.com/Canto-Network/Canto).
