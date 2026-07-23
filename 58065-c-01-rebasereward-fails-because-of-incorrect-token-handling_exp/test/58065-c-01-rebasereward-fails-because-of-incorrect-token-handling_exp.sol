// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./58065-c-01-rebasereward-fails-because-of-incorrect-token-handling.sol";

/* KittenSwap C-01 — RebaseReward deposits Kitten for non-Kitten incentives (Pashov 2025-06) */
contract PoC_58065 is Test {
    function test_rebaseRewardBrokenRewards() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.user1Claimed(), e.KITTEN_REWARD(), "user1 drained all Kitten");
        assertEq(e.ve().locked(e.TOKEN_ID_1()), e.KITTEN_REWARD());
        assertEq(e.ve().locked(e.TOKEN_ID_2()), 0, "user2 got nothing");
        assertEq(e.otherToken().balanceOf(address(e.rebase())), e.OTHER_REWARD(), "other stuck in RR");
        assertEq(e.kitten().balanceOf(address(e.rebase())), 0, "Kitten emptied from RR");
    }
}
