# Reserve custom redemption with an unregistered old asset

This POC executes the vulnerable Reserve `AssetRegistry`/redemption source vendored under `src/reserve/` at the audited pre-fix revision. The test unregisters the old asset and calls the real custom redemption path, which reverts as reported.

```bash
forge test -vvv
```

Sources: [AuditVault finding #27331](https://github.com/Auditware/AuditVault/blob/main/findings/27331-h-01-custom-redemption-might-revert-if-old-assets-were-unreg.md), [Reserve repository](https://github.com/reserve-protocol/protocol).
