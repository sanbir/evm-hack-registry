// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./27531-h-41-rewards-compounded-in-aavestrategy-are-unredeemable-cod.sol";

contract UnredeemableRewardsTest is Test {
    function test_compound_locks_rewards_as_stk() public {
        Exploit exp = new Exploit();
        exp.run();
        assertEq(exp.lockedStk(), exp.REWARD());
        assertEq(exp.aave().balanceOf(address(exp.strategy())), 0);
    }
}
