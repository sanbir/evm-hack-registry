# Symmio liquidation signature replay

The test runs the historical Symmio liquidation facet and Muon-signature code vendored under `src/symm/`. It submits the same valid liquidation signature twice through `liquidatePartyA` and observes the replay path in the real implementation.

```bash
forge test -vvv
```

Sources: [Sherlock Symmio report](https://github.com/sherlock-audit/2023-08-symmetrical-judging), [AuditVault finding #26346](https://github.com/Auditware/AuditVault/blob/main/findings/26346-h-1-liquidatepartya-requires-signature-which-doesnt-have-non.md).
