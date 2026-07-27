# Origin Dollar: unchecked token return value

This POC compiles the historical Origin Dollar source vendored under `src/strategies/CompoundStrategy.sol` and `src/utils/InitializableAbstractStrategy.sol`. A non-compliant token returns `false` on the real strategy call; the test verifies that the vulnerable source continues as reported.

```bash
forge test -vvv
```

Sources: [Origin Dollar audit](https://github.com/trailofbits/publications/blob/master/reviews/OriginDollar.pdf), [AuditVault finding #18210](https://github.com/Auditware/AuditVault/blob/main/findings/18210-lack-of-return-value-checks-can-lead-to-unexpected-results-t.md).
