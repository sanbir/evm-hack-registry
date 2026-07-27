// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import "forge-std/Test.sol";
import {CDSLib} from "../src/lib/CDSLib.sol";
import {CDSInterface} from "../src/interface/CDSInterface.sol";
import {IBorrowing} from "../src/interface/IBorrowing.sol";
import {ITreasury} from "../src/interface/ITreasury.sol";
import {IUSDa} from "../src/interface/IUSDa.sol";

contract TreasuryApprovalDouble {
    function approveTokens(IBorrowing.AssetName, address, uint256) external {}
}

contract USDaTransferDouble {
    function contractTransferFrom(address, address, uint256) external pure returns (bool) { return true; }
}

contract PoC_45465_CDSAggregateAccounting is Test {
    function testLossAdjustedDepositLeavesAggregateTooHigh() public {
        TreasuryApprovalDouble treasury = new TreasuryApprovalDouble();
        USDaTransferDouble usda = new USDaTransferDouble();

        CDSInterface.Interfaces memory interfaces;
        interfaces.treasury = ITreasury(address(treasury));
        interfaces.usda = IUSDa(address(usda));
        interfaces.cds = CDSInterface(address(this));

        CDSInterface.WithdrawUserParams memory params;
        // CDS.withdraw has already overwritten the original 400 position with
        // its loss-adjusted 360 return before this library is called.
        params.cdsDepositDetails.depositedAmount = 360;
        params.returnAmount = 360;
        params.omniChainData.totalCdsDepositedAmount = 1_000;
        params.omniChainData.totalCdsDepositedAmountWithOptionFees = 1_000;

        CDSInterface.WithdrawResult memory result = CDSLib.withdrawUserWhoNotOptedForLiq(
            params,
            interfaces,
            1_000,
            1_000
        );

        // The audited implementation subtracts the overwritten 360 instead
        // of the original 400, leaving 640 recorded while the other depositor
        // still owns 600 of the 1,000 pool.
        assertEq(result.totalCdsDepositedAmount, 640);
        assertEq(uint256(1_000 - 400), uint256(600));
        assertGt(result.totalCdsDepositedAmount, uint256(1_000 - 400));
    }

    function testCdsAmountToReturnIsTheSameHistoricalImplementation() public pure {
        CDSInterface.CdsAccountDetails memory depositData;
        depositData.depositedAmount = 1_000;
        depositData.depositValueSign = true;

        CDSInterface.CalculateValueResult memory loss = CDSInterface.CalculateValueResult(1e10, false);
        uint256 afterLoss = CDSLib.cdsAmountToReturn(depositData, loss, 0, true);
        assert(afterLoss == 900);

        CDSInterface.CalculateValueResult memory recovery = CDSInterface.CalculateValueResult(1e10, true);
        uint256 afterRecovery = CDSLib.cdsAmountToReturn(depositData, recovery, 1e10, false);
        assert(afterRecovery == 1_000);
    }
}
