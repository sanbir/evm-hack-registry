# Symmio staking rewards can be skipped by frequent updates

This POC executes the historical `SymmStaking` source vendored under `src/symm/contracts/staking/SymmStaking.sol`. It triggers `_updateRewardsStates` at the audited cadence and verifies the USDC reward distribution loss.

```bash
forge test -vvv
```

Sources: [Sherlock Symmio staking report](https://github.com/sherlock-audit/2025-03-symm-io-stacking-judging), [AuditVault finding #55104](https://github.com/Auditware/AuditVault/blob/main/findings/55104-h-1-usdc-rewards-will-not-be-distributed-if-updaterewardsst.md).
