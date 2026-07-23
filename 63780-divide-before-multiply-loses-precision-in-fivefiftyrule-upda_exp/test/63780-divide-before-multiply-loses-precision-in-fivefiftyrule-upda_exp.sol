// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./63780-divide-before-multiply-loses-precision-in-fivefiftyrule-upda.sol";

contract FiveFiftyDivBeforeMulTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();

        uint256 exposure = e.rule().lookThroughExposure(e.ENTITY());
        uint256 cap = e.rule().capAmountMicros(e.CATALYST());
        assertGt(exposure, cap, "exposure exceeds cap due to precision loss");
    }

    function test_buggyDeltaTruncates() public {
        FiveFiftyRule rule = new FiveFiftyRule();
        uint64 equity = 333_334;
        uint64 amount = 1_500_000;
        uint256 correct = rule.correctDelta(equity, amount);
        uint256 buggy = rule.buggyDelta(equity, amount);
        // DENOM/equity = 1_000_000/333_334 = 2 (truncated); 2*amount = 3_000_000
        // correct = 1_000_000*amount/equity ≈ 4_500_009
        assertLt(buggy, correct, "div-before-mul truncates");
        assertEq(buggy, 3_000_000, "buggy delta");
    }
}
