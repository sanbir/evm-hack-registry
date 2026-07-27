# LoopFi prelaunch deposit availability invariant

This POC executes the historical LoopFi `PrelaunchPoints` source vendored under `src/loopfi/`. The test uses the real deposit/claim accounting and shows the availability invariant can be bypassed.

```bash
forge test -vvv
```

Sources: [AuditVault finding #33354](https://github.com/Auditware/AuditVault/blob/main/findings/33354-h-01-availability-of-deposit-invariant-can-be-bypassed-code4.md), [Code4rena report](https://code4rena.com/reports/2024-04-loop).
