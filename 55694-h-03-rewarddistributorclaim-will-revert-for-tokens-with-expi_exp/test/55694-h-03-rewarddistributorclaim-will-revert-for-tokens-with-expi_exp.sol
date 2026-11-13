// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {
    Exploit,
    PegToken,
    RewardsDistributorFixed,
    VotingEscrow
} from "./55694-h-03-rewarddistributorclaim-will-revert-for-tokens-with-expi.sol";

contract Finding55694Test is Test {
    function test_exploit_expired_lock_locks_rewards() public {
        Exploit e = new Exploit();
        e.run();

        assertFalse(e.expiredClaimed(), "expired claim reverted");
        assertTrue(e.activeClaimed(), "live lock still claims");
        assertEq(e.stuckInDistributor(), 1_000 ether, "1000 PEG stuck");
        assertEq(e.activeLockPeg(), 1 ether + 1_000 ether, "live lock compounded");
        assertEq(e.dist().token_last_balance(), 1_000 ether, "only the live claim reduced the balance");
    }

    function test_control_fixed_pays_expired_lock_directly() public {
        PegToken token = new PegToken();
        VotingEscrow escrow = new VotingEscrow(token);
        RewardsDistributorFixed fixedDist = new RewardsDistributorFixed(token, escrow);
        address owner = address(0xB0B);

        token.mint(address(this), 2 ether + 1_000 ether);
        token.approve(address(escrow), 1 ether);
        token.approve(address(fixedDist), 1_000 ether);
        escrow.create_lock(1, 1 ether, block.timestamp);
        fixedDist.setOwner(1, owner);
        fixedDist.notifyReward(1, 1_000 ether);

        uint256 paid = fixedDist.claim(1);
        assertEq(paid, 1_000 ether, "paid");
        assertEq(token.balanceOf(owner), 1_000 ether, "owner received PEG");
        assertEq(token.balanceOf(address(fixedDist)), 0, "nothing stuck");
    }
}
