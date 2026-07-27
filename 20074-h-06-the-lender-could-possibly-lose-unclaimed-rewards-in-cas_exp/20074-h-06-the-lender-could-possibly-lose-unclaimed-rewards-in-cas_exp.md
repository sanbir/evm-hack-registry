# Ajna bankrupt bucket can lose unclaimed lender rewards

The test executes the historical Ajna `PositionManager` and reward accounting vendored under `src/ajna/`. It reproduces the lender position path and asserts the unclaimed reward loss in the real code.

```bash
forge test -vvv
```

Sources: [AuditVault finding #20074](https://github.com/Auditware/AuditVault/blob/main/findings/20074-h-06-the-lender-could-possibly-lose-unclaimed-rewards-in-cas.md), [Ajna repository](https://github.com/ajna-finance/ajna-core).
