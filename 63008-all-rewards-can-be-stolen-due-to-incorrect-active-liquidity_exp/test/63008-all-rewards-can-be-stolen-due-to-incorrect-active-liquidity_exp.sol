// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./63008-all-rewards-can-be-stolen-due-to-incorrect-active-liquidity.sol";

contract SorellaRewardsTheftTest is Test {
    function test_exploit_stealAllRewardsViaBoundaryTick() public {
        Exploit e = new Exploit();
        e.run();

        assertGt(e.rewardsStolen(), 0, "attacker stole rewards");
        assertGe(e.rewardsStolen(), 500e18, "majority of R stolen");
        assertGt(e.rewardsStolen(), e.honestPending(), "attacker > honest");
        assertEq(e.token().balanceOf(address(e)), e.rewardsStolen(), "profit on exploit");
    }
}
