// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    DepositManagerBuggy,
    DepositManagerFixed,
    MiniToken
} from "./65376-depositmanagergetrewards-always-includes-referrer-fee-result.sol";

contract GetRewardsAlwaysDeductsReferrerFeeTest is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    address internal constant WINNER = 0x1111111111111111111111111111111111111111;
    address internal constant CREATOR = 0x0000000000000000000000000000000000000C0C;
    address internal constant PROTOCOL = 0x0000000000000000000000000000000000000d01;

    uint256 internal constant GAME = 1;
    uint256 internal constant TICKET = 100 ether;
    uint256 internal constant PLAYERS = 10;
    uint256 internal constant CREATOR_FEE = 500;

    function test_exploit_getRewardsStrandsReferrerFeeWhenNoReferrers() public {
        Exploit e = new Exploit();
        e.run();

        // Pool = 10 players * 100e18 = 1000e18.
        assertEq(e.totalPool(), 1000 ether, "pool");

        // Buggy getRewards pays the winner only 88% (100% - 5% creator - 5% protocol
        // - 2% referrer). The correct amount with no referrers is 90% (900e18).
        assertEq(e.winnerReward(), 880 ether, "winner under-paid by the 2% referrer slice");

        // Harm: exactly 2% of the pool (20e18) is stranded in the manager, unclaimable,
        // and equals the referral owed to address(0) (which nobody can claim).
        assertEq(e.buggyResidual(), 20 ether, "2% of pool stranded");
        assertGt(e.buggyResidual(), 0, "funds stranded");
        assertEq(e.lockedReferral(), 20 ether, "stranded == address(0) referral");

        MiniToken token = MiniToken(e.tokenAddr());
        assertEq(token.balanceOf(e.managerAddr()), 20 ether, "manager still holds the stranded 2%");

        // address(0) can never call claimReferralReward, so the 20e18 is permanently locked.
        // The winner, creator and protocol have all been paid their full amounts.
        assertEq(token.balanceOf(WINNER), 880 ether, "winner paid 88%");
        assertEq(token.balanceOf(CREATOR), 50 ether, "creator paid 5%");
        assertEq(token.balanceOf(PROTOCOL), 50 ether, "protocol paid 5%");

        // Marker records the locked magnitude at the SINK.
        MiniToken marker = MiniToken(e.markerAddr());
        assertEq(marker.balanceOf(SINK), 20 ether, "marker records 2% locked at SINK");
    }

    function test_control_fixedFormula_leavesNoResidual() public {
        // Rebuild the identical no-referrer scenario against the FIXED contract.
        MiniToken token = new MiniToken("Game", "GAME");
        DepositManagerFixed mgr = new DepositManagerFixed();
        mgr.createGamePool(GAME, TICKET, CREATOR_FEE, address(token));

        token.mint(address(this), TICKET * PLAYERS);
        token.approve(address(mgr), type(uint256).max);
        for (uint256 i = 0; i < PLAYERS; i++) {
            mgr.payEntryFee(GAME, address(0));
        }

        uint256 reward = mgr.getRewards(GAME); // fixed: 90% of pool = 900e18
        assertEq(reward, 900 ether, "fixed pays the full 90% to the winner");
        mgr.distributeRewards(GAME, WINNER, reward);
        mgr.distributeFees(GAME, CREATOR, PROTOCOL);

        // Nothing is stranded: the winner absorbs the slice that the buggy formula withheld.
        assertEq(token.balanceOf(address(mgr)), 0, "fixed formula strands nothing");
        assertEq(token.balanceOf(WINNER), 900 ether, "winner paid full 90%");
        assertEq(token.balanceOf(CREATOR), 50 ether, "creator paid 5%");
        assertEq(token.balanceOf(PROTOCOL), 50 ether, "protocol paid 5%");
    }
}
