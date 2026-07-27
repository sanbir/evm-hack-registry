// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import "forge-std/Test.sol";
import {CDSLib} from "../src/lib/CDSLib.sol";
import {CDSInterface} from "../src/interface/CDSInterface.sol";

contract PoC_45464_CDSLossRecovery is Test {
    function testEqualRecoveryRestoresAnAlreadyLostDeposit() public {
        CDSInterface.CdsAccountDetails memory depositData;
        depositData.depositedAmount = 1_000;
        depositData.depositValue = 0;
        depositData.depositValueSign = true;

        // A 10% cumulative loss is represented by 1e10 (the real library
        // divides depositedAmount * value by 1e11).
        CDSInterface.CalculateValueResult memory loss = CDSInterface.CalculateValueResult({
            currentValue: 1e10,
            gains: false
        });
        uint256 afterLoss = CDSLib.cdsAmountToReturn(depositData, loss, 0, true);
        assertEq(afterLoss, 900, "the real loss path should return 90%");

        // The price recovers by the same amount. The historical sign/cumulative
        // algorithm now returns the original 1,000, even though the protection
        // was consumed during the earlier withdrawal.
        CDSInterface.CalculateValueResult memory recovery = CDSInterface.CalculateValueResult({
            currentValue: 1e10,
            gains: true
        });
        uint256 afterRecovery = CDSLib.cdsAmountToReturn(depositData, recovery, 1e10, false);
        assertEq(afterRecovery, 1_000, "real vulnerable recovery restores the loss");
        assertGt(afterRecovery, afterLoss, "later depositors absorb the restored amount");
    }
}
