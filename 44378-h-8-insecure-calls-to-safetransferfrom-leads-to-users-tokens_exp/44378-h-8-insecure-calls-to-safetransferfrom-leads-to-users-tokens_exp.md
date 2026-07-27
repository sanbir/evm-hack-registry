# Oku `safeTransferFrom` uses an attacker-controlled source

The test executes the historical Oku order/stop-limit contracts vendored under `src/oku/`. It supplies a victim as the transfer source through the real call path and verifies the victim's token balance is transferred.

```bash
forge test -vvv
```

Sources: [Sherlock Oku report](https://github.com/sherlock-audit/2024-11-oku-judging), [AuditVault finding #44378](https://github.com/Auditware/AuditVault/blob/main/findings/44378-h-8-insecure-calls-to-safetransferfrom-leads-to-users-tokens.md).
