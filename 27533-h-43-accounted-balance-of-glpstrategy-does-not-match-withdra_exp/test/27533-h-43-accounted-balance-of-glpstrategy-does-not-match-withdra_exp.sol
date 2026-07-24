// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./27533-h-43-accounted-balance-of-glpstrategy-does-not-match-withdra.sol";

contract GlpRewardsTheftTest is Test {
    function test_steal_unclaimed_rewards() public {
        Exploit exp = new Exploit();
        exp.run();
        assertEq(exp.profit(), exp.PENDING() / 2);
    }
}
