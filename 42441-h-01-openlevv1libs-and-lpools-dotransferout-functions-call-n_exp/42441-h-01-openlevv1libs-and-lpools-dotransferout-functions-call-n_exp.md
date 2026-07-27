# OpenLev native `transfer` stipend

This POC executes the historical `OpenLevV1Lib` and `LPool` transfer code vendored under `src/poc/`. A contract recipient with a fallback requiring more than the 2300-gas stipend is used on the real `doTransferOut` path, which reverts as reported.

```bash
forge test -vvv
```

Sources: [AuditVault finding #42441](https://github.com/Auditware/AuditVault/blob/main/findings/42441-h-01-openlevv1libs-and-lpools-dotransferout-functions-call-n.md), [OpenLev repository](https://github.com/level-finance/openlev-contracts).
