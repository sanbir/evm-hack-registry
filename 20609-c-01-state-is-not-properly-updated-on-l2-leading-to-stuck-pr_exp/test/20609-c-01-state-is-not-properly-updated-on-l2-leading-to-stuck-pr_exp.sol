// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    L2DenFixed,
    Prize,
    SleeperNFT
} from "./20609-c-01-state-is-not-properly-updated-on-l2-leading-to-stuck-pr.sol";

contract Finding20609Test is Test {
    function test_three_prizes_stay_stuck_on_l2() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.l1Length(), 3, "L1 recorded the 3 adds");
        assertEq(e.l2Length(), 7, "L2 length stayed 7");
        assertEq(e.woken(), 7, "only the synced sleepers wake");
        assertTrue(e.eighthReverted(), "8th wake reverts");
        assertEq(e.stuckOwnedByDen(), 3, "N = 3 NFTs still owned by the den");
        assertEq(e.denPrizeLeft(), 300 ether, "300 PRIZE stuck");
        assertEq(e.claimerPrize(), 700 ether, "7 prizes paid");
    }

    function test_control_mirror_lets_all_ten_wake() public {
        Prize prize = new Prize();
        SleeperNFT nft = new SleeperNFT();
        L2DenFixed l2 = new L2DenFixed(prize, nft);
        uint256 i;
        for (i = 1; i <= 7; i++) {
            nft.mint(address(l2), i);
            l2.seed(1, i, 100 ether);
        }
        for (i = 8; i <= 10; i++) {
            nft.mint(address(l2), i);
            l2.mirror(1, i, 100 ether);
        }
        prize.mint(address(l2), 1000 ether);
        for (i = 0; i < 10; i++) {
            l2.wakeSleeper(1);
        }
        assertEq(l2.numUsed(1), 10, "mirrored length wakes every sleeper");
        assertEq(prize.balanceOf(address(l2)), 0, "den is empty");
        assertEq(prize.balanceOf(address(this)), 1000 ether, "claimer receives N = 10 prizes");
        assertEq(nft.ownerOf(10), address(this), "last nft left the den");
    }
}
