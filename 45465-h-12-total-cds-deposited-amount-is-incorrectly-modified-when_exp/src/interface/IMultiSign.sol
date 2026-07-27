// SPDX-License-Identifier: MIT

pragma solidity 0.8.22;

interface IMultiSign {
    enum SetterFunctions {
        SetLTV,
        SetAPR,
        SetWithdrawTimeLimitCDS,
        SetAdminBorrow,
        SetAdminCDS,
        SetTreasuryBorrow,
        SetTreasuryCDS,
        SetBondRatio,
        SetUSDaLimit,
        SetUsdtLimit
    }
    enum Functions {
        BorrowingDeposit,
        BorrowingWithdraw,
        Liquidation,
        SetAPR,
        CDSDeposit,
        CDSWithdraw,
        RedeemUSDT
    }

    function functionState(Functions) external returns (bool);

    function executeSetterFunction(
        SetterFunctions _function
    ) external returns (bool);
}
