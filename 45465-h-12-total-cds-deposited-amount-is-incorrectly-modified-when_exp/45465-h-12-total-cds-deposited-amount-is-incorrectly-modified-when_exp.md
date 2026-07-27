# Autonomint CDS withdrawal mis-accounted a lossy depositor

> **Vulnerability classes:** vuln/reward-accounting · vuln/locked-funds · vuln/integer-bounds
>
> **Reproduction:** the test compiles the audited Autonomint `CDSLib.sol` at Sherlock snapshot `0d324e04d4c0ca306e1ae4d4c65f0cb9d681751b` and calls the real `withdrawUserWhoNotOptedForLiq` path with only Treasury/USDa boundary doubles.

<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/45465-h-12-total-cds-deposited-amount-is-incorrectly-modified-when.md -->
<!-- date: 2024-11 -->

## Root cause

After a lossy withdrawal, `CDS.withdraw` writes the loss-adjusted amount into `cdsDepositDetails.depositedAmount`. The audited library then subtracts that adjusted amount from `totalCdsDepositedAmount` (and the omnichain copy) rather than removing the original position. A 400-unit position reduced to 360 leaves a 1,000-unit pool recorded as 640 even though the other depositor owns 600.

The exact library and interface sources are vendored at [`src/lib/CDSLib.sol`](src/lib/CDSLib.sol) and [`src/interface`](src/interface).

## Reproduction

```bash
cd 45465-h-12-total-cds-deposited-amount-is-incorrectly-modified-when_exp
forge test -vvv
```

Expected result: `2 passed`. The first test asserts the exact vulnerable return values (`640` recorded versus `600` actual remaining); the second exercises the exact `cdsAmountToReturn` implementation after an equal price loss/recovery and returns the original 1,000-unit position.

## Sources

- [AuditVault finding #45465](https://github.com/Auditware/AuditVault/blob/main/findings/45465-h-12-total-cds-deposited-amount-is-incorrectly-modified-when.md)
- [Sherlock Autonomint source snapshot](https://github.com/sherlock-audit/2024-11-autonomint/tree/0d324e04d4c0ca306e1ae4d4c65f0cb9d681751b/Blockchain/Blockchian/contracts)
- [Sherlock issue #738](https://github.com/sherlock-audit/2024-11-autonomint-judging/issues/738)
