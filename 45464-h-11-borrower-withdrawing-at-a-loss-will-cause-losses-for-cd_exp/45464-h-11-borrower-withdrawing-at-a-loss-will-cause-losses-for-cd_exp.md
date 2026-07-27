# Autonomint CDS loss accounting let an earlier depositor recover at later depositors' expense

> **Vulnerability classes:** vuln/liquidation-logic · vuln/reward-accounting · vuln/first-deposit
>
> **Reproduction:** the test calls the audited `CDSLib.cdsAmountToReturn` implementation from the Sherlock Autonomint snapshot. It models the exact 10% cumulative loss followed by an equal recovery.

<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/45464-h-11-borrower-withdrawing-at-a-loss-will-cause-losses-for-cd.md -->
<!-- date: 2024-11 -->

## Root cause

The first CDS depositor's return is calculated from the cumulative value at deposit and withdrawal. A down-then-up price path brings that cumulative value back to its original value, so the first depositor receives the full original deposit even though downside protection was consumed during the loss. Later depositors absorb that shortfall.

The exact library is vendored at [`src/lib/CDSLib.sol`](src/lib/CDSLib.sol), from snapshot commit `0d324e04d4c0ca306e1ae4d4c65f0cb9d681751b`.

## Reproduction

```bash
cd 45464-h-11-borrower-withdrawing-at-a-loss-will-cause-losses-for-cd_exp
forge test -vvv
```

Expected result: `1 passed`. The test obtains 900 after the loss, then 1,000 after the equal recovery using the real `cdsAmountToReturn` implementation.

## Sources

- [AuditVault finding #45464](https://github.com/Auditware/AuditVault/blob/main/findings/45464-h-11-borrower-withdrawing-at-a-loss-will-cause-losses-for-cd.md)
- [Sherlock Autonomint source snapshot](https://github.com/sherlock-audit/2024-11-autonomint/tree/0d324e04d4c0ca306e1ae4d4c65f0cb9d681751b/Blockchain/Blockchian/contracts)
- [Sherlock issue #734](https://github.com/sherlock-audit/2024-11-autonomint-judging/issues/734)
