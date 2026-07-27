# Olas L2 dispenser accepts arbitrary bridged token/data

The test executes the historical Olas `GnosisTargetDispenserL2` source vendored under `src/olas/`. Boundary doubles model only the bridge endpoint; the token/data acceptance and incentive accounting are the real audited code.

```bash
forge test -vvv
```

Sources: [AuditVault finding #34921](https://github.com/Auditware/AuditVault/blob/main/findings/34921-h-02-arbitrary-tokens-and-data-can-be-bridged-to-gnosistarge.md), [Olas repository](https://github.com/valory-xyz/autonolas-governance).
