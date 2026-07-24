// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./42551-h-02-dos-blacklisted-user-may-prevent-withdrawexcessrewards.sol";

/* FactoryDAO H-02 — blacklisted depositor DoS on withdrawExcessRewards */
contract PoC_42551 is Test {
    function test_blacklisted_user_blocks_excess_rewards() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.factory().totalDeposits(e.poolId()), e.ATTACKER_DEP());
        assertGt(e.factory().rewardFundingOf(e.poolId(), 0), 0);
        assertGt(e.rewardTok().balanceOf(address(e.factory())), 0);
    }
}
