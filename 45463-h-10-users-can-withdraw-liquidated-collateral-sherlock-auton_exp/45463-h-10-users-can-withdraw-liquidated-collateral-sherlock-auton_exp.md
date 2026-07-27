# Autonomint `liquidationType2` did not mark the borrower liquidated

> **Vulnerability classes:** vuln/liquidation-logic · vuln/direct-drain · vuln/accounting
>
> **Reproduction:** the test compiles the audited `BorrowLiquidation.sol` and `BorrowLib.sol` snapshot and invokes the real `liquidationType2` path through its `onlyBorrowingContract` entry point. WETH, wrapper, Synthetix, and Treasury are protocol-boundary doubles only.

<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/45463-h-10-users-can-withdraw-liquidated-collateral-sherlock-auton.md -->
<!-- date: 2024-11 -->

## Root cause

`liquidationType1` sets `depositDetail.liquidated = true` and persists the updated detail. `liquidationType2` performs the short-position flow but never persists that state change. A subsequent borrowing withdrawal therefore still sees the position as live and can withdraw collateral already sent to Synthetix.

The exact vulnerable sources are vendored at [`src/Core_logic/borrowLiquidation.sol`](src/Core_logic/borrowLiquidation.sol) and [`src/lib/BorrowLib.sol`](src/lib/BorrowLib.sol), from Sherlock snapshot `0d324e04d4c0ca306e1ae4d4c65f0cb9d681751b`.

## Reproduction

```bash
cd 45463-h-10-users-can-withdraw-liquidated-collateral-sherlock-auton_exp
forge test -vvv
```

Expected result: `1 passed`. The assertion confirms that after the exact type-2 liquidation call the Treasury still reports `liquidated == false` and the full original collateral remains withdrawable.

## Sources

- [AuditVault finding #45463](https://github.com/Auditware/AuditVault/blob/main/findings/45463-h-10-users-can-withdraw-liquidated-collateral-sherlock-auton.md)
- [Sherlock Autonomint source snapshot](https://github.com/sherlock-audit/2024-11-autonomint/tree/0d324e04d4c0ca306e1ae4d4c65f0cb9d681751b/Blockchain/Blockchian/contracts)
- [Sherlock issue #696](https://github.com/sherlock-audit/2024-11-autonomint-judging/issues/696)
