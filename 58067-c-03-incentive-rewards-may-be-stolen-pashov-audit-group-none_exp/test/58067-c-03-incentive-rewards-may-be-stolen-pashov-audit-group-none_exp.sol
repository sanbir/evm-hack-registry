// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    USDC,
    VeKitten,
    Victim,
    Voter,
    VotingRewardFixed
} from "./58067-c-03-incentive-rewards-may-be-stolen-pashov-audit-group-none.sol";

contract Finding58067Test is Test {
    uint256 constant AMOUNT = 500_000_000;

    function test_attacker_receives_the_victims_500_usdc() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.stolen(), AMOUNT, "attacker received the victim's 500 USDC");
        assertEq(e.usdc().balanceOf(address(e)), AMOUNT, "attacker balance");
        assertEq(e.usdc().balanceOf(address(e.victim())), 0, "victim balance");
        assertEq(e.usdc().balanceOf(address(e.rewards())), 0, "pool drained");
    }

    function test_control_pays_the_victim() public {
        vm.warp(1);
        USDC usdc = new USDC();
        Voter voter = new Voter();
        VeKitten ve = new VeKitten();
        VotingRewardFixed rewards = new VotingRewardFixed(voter, ve);
        Victim victim = new Victim();
        uint256 tokenId = 7;
        uint256 period = rewards.getCurrentPeriod() + 1;

        voter.setWhitelisted(address(usdc), true);
        ve.setOwner(tokenId, address(victim));
        usdc.mint(address(victim), AMOUNT);
        victim.fund(rewards, usdc, AMOUNT);
        victim.vote(voter, rewards, 100, tokenId);

        vm.expectRevert(VotingRewardFixed.FuturePeriod.selector);
        victim.claim(rewards, period, tokenId, address(usdc));
        assertEq(usdc.balanceOf(address(victim)), 0, "early claim paid nothing");

        vm.warp(7 days);
        victim.claim(rewards, period, tokenId, address(usdc));

        assertEq(usdc.balanceOf(address(victim)), AMOUNT, "control pays the victim 500 USDC");
        assertEq(usdc.balanceOf(address(rewards)), 0, "pool empty");
        assertEq(usdc.balanceOf(address(this)), 0, "attacker was not paid");
    }
}
