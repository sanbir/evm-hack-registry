# Ajna reward remainder calculation

This POC calls the real Ajna `RewardsManager`/reward calculation code vendored under `src/ajna/`. The test drives a bucket-reward update and observes the incorrect remaining `updatedRewards` value from the audited implementation.

```bash
forge test -vvv
```

Sources: [AuditVault finding #20073](https://github.com/Auditware/AuditVault/blob/main/findings/20073-h-05-incorrect-calculation-of-the-remaining-updatedrewards-l.md), [Ajna repository](https://github.com/ajna-finance/ajna-core).
