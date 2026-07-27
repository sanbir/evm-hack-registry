# NLX reader fetches an oracle price repeatedly

This POC executes the historical NLX reader/order source vendored under `src/nlx/`. The test uses a changing oracle response during one real pricing path and verifies the repeated-fetch/arbitrage condition.

```bash
forge test -vvv
```

Sources: [AuditVault finding #50882](https://github.com/Auditware/AuditVault/blob/main/findings/50882-multiple-price-fetches-leading-to-arbitrage-in-oracle-implem.md), [GMX/NLX source family](https://github.com/gmx-io/gmx-synthetics).
