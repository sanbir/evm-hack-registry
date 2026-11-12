// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, VotingEscrowFixed} from "./58016-h-05-incorrect-last-pointblk-calculation-due-to-shared-memor.sol";

contract SharedPointTest is Test {
    uint256 internal constant BLOCK = 1_000_000;
    uint256 internal constant WHEN = 1_700_697_600;
    uint256 internal constant LOW = 604_800_000_000_000_000_000;
    uint256 internal constant HIGH = 1_209_600_000_000_000_000_000;

    function test_exploit_historicalBlockStaysAndRewardIsLow() public {
        vm.roll(BLOCK);
        vm.warp(WHEN);
        Exploit e = new Exploit();
        e.run();

        assertEq(e.historicalBlk(), 800_000, "blk stuck");
        assertEq(e.paid(), LOW, "decayed bias");
        assertEq(e.shortfall(), LOW, "short one week");
        assertEq(e.token().balanceOf(address(e)), LOW, "balance");
    }

    function test_control_freshPointAdvancesTheBlockAndPaysHigh() public {
        vm.roll(BLOCK);
        vm.warp(WHEN);
        VotingEscrowFixed fixedEscrow = new VotingEscrowFixed();
        (uint256 blk, uint256 votes) = fixedEscrow.checkpoint();

        assertGt(blk, 800_000, "fresh copy advanced blk");
        assertEq(votes, HIGH, "vote at the old block keeps the full bias");
        assertEq(blk, 899_999, "one week of slope");
    }
}
