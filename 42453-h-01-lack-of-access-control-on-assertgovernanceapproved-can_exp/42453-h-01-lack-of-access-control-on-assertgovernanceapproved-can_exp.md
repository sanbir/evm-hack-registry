# Behodler governance approval access control

The test executes the historical Behodler governance/DAO contracts vendored under `src/behodler/`. An arbitrary caller reaches `assertGovernanceApproved` through the real proposal path and the test verifies the resulting lock condition.

```bash
forge test -vvv
```

Sources: [AuditVault finding #42453](https://github.com/Auditware/AuditVault/blob/main/findings/42453-h-01-lack-of-access-control-on-assertgovernanceapproved-can.md), [Behodler repository](https://github.com/Behodler/Behodler2).
