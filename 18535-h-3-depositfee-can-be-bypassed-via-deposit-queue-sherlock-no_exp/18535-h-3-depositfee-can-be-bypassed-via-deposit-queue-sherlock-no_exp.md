# Y2K `depositFee` bypass through the deposit queue

The test executes the audited Y2K `VaultV2` queue and fee code vendored under `src/v2/`. It deposits through the real queue path and shows that the fee calculation can be bypassed as reported.

```bash
forge test -vvv
```

Sources: [Sherlock Y2K report](https://github.com/sherlock-audit/2023-03-Y2K-judging), [AuditVault finding #18535](https://github.com/Auditware/AuditVault/blob/main/findings/18535-h-3-depositfee-can-be-bypassed-via-deposit-queue-sherlock-no.md).
