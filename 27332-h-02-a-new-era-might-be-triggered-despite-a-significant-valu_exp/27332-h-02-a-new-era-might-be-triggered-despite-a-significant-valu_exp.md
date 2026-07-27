# Reserve can start a new era while old value remains

The test executes the historical Reserve era/redemption source vendored under `src/reserve/`. It preserves value in the old era, invokes the real transition, and asserts the premature new-era state.

```bash
forge test -vvv
```

Sources: [AuditVault finding #27332](https://github.com/Auditware/AuditVault/blob/main/findings/27332-h-02-a-new-era-might-be-triggered-despite-a-significant-valu.md), [Reserve repository](https://github.com/reserve-protocol/protocol).
