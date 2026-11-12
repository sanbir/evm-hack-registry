// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, StakingKo, StakingKoFixed, RewardToken} from "./49514-h-02-users-might-not-be-able-to-fully-claim-shieldify-none-b.sol";

contract FullClaimGasTest is Test {
    uint256 internal constant FAIR = 1600 ether;

    function test_exploit_nestedClaimPaysLessThanFair() public {
        Exploit e = new Exploit();
        e.run();

        assertLt(e.paidBuggy(), FAIR, "paid");
        assertEq(e.paidBuggy() + e.stuck(), FAIR, "shortfall stays");
        assertEq(e.paidControl(), FAIR, "control");
        assertEq(e.reward().balanceOf(address(e)), FAIR, "user");
    }

    function test_control_sameBudgetPaysTheFairAmount() public {
        RewardToken reward = new RewardToken();
        StakingKo buggy = new StakingKo(address(reward));
        StakingKoFixed control = new StakingKoFixed(address(reward));
        reward.mint(address(buggy), FAIR);
        reward.mint(address(control), FAIR);

        uint256 budget = 250_000;
        (bool buggyOk,) = address(buggy).call{gas: budget}(abi.encodeWithSignature("fullyClaimReward()"));
        (bool controlOk,) = address(control).call{gas: budget}(abi.encodeWithSignature("fullyClaimReward()"));

        assertFalse(buggyOk, "nested claim should not finish");
        assertTrue(controlOk, "flat claim should finish");
        assertEq(buggy.paid(), 0, "buggy paid");
        assertEq(control.paid(), FAIR, "control paid");
        assertEq(reward.balanceOf(address(this)), FAIR, "user received the fair amount");
    }
}
