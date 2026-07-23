// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./63719-h-01-bonuses-obtainable-without-proper-locking-due-to-flawed.sol";

contract BobFreeBonusTest is Test {
    function test_bonus_without_locking() public {
        Exploit e = new Exploit();
        e.run();

        assertTrue(e.stillUnlocked(), "unlocked");
        assertEq(e.bonusStolen(), 800e18, "bonus");
        assertEq(e.stakedAmount(), 1600e18, "principal+bonus staked");
        (, uint80 lockPeriod,) = e.staking().stakers(address(e));
        assertEq(lockPeriod, 0, "lock stays 0");
    }
}
