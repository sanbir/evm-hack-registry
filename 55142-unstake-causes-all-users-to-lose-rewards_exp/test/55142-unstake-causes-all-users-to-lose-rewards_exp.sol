// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./55142-unstake-causes-all-users-to-lose-rewards.sol";

contract UnstakeZerosRewardsTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.sharesAfterUnstake(), 0, "pool shares zeroed");
        assertEq(e.userRewardAfter(), 0, "user rewards wiped");
        assertEq(e.sharesBeforeUnstake(), 2000, "both had staked");
    }
}
