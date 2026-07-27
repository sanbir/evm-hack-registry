# MuteBond front-run changes a bond buyer's payout

This POC executes the audited MuteBond implementation vendored under `src/mute/contracts/MuteBond.sol` (the historical Code4rena source), not a rewritten reduction. The test performs the real repeated `deposit` path and demonstrates the epoch/payout change after front-running.

```bash
forge test -vvv
```

Sources: [MuteBond audited source](https://github.com/code-423n4/2023-03-mute/blob/4d8b13add2907b17ac14627cfa04e0c3cc9a2bed/contracts/bonds/MuteBond.sol), [AuditVault finding #16039](https://github.com/Auditware/AuditVault/blob/main/findings/16039-h-02-attacker-can-front-run-bond-buyer-and-make-them-buy-it.md).
