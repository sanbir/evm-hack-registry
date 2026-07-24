// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./27534-h-44-bigbangrepay-and-singularityrepay-spend-more-than-allow.sol";

contract RepayOverAllowTest is Test {
    function test_repay_pulls_more_than_allowed_part() public {
        Exploit exp = new Exploit();
        exp.run();
        assertGt(exp.pulled(), exp.ALLOWED_PART());
        assertGt(exp.overspend(), 0);
    }
}
