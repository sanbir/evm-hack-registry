# TraitForge minting count across generations

This POC executes the historical TraitForge `Nft`/minting implementation vendored under `src/traitforge/`. The test mints across generations through the actual contract and demonstrates the incorrect total-count calculation.

```bash
forge test -vvv
```

Sources: [AuditVault finding #37915](https://github.com/Auditware/AuditVault/blob/main/findings/37915-h-01-wrong-minting-logic-based-on-total-token-count-across-g.md), [Code4rena report](https://code4rena.com/reports/2023-07-traitforge).
