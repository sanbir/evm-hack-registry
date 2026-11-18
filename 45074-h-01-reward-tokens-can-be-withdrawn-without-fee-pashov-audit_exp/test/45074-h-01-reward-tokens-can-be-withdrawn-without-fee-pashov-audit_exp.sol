// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import {Exploit} from "./45074-h-01-reward-tokens-can-be-withdrawn-without-fee-pashov-audit.sol";
contract Finding45074Test is Test {
    function test_exploit_reward_leaves_with_no_fee() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.reward().balanceOf(address(e)), 1000 ether, "attacker");
        assertEq(e.reward().balanceOf(address(e.beekeeper())), 0, "fee");
        assertTrue(e.queen().isRewardToken(address(e.reward())), "reward token");
    }
    function test_control_withdrawERC20_pays_10_percent() public {
        Exploit e = new Exploit();
        e.withdrawHonest();
        assertEq(e.reward().balanceOf(address(e)), 900 ether, "user net");
        assertEq(e.reward().balanceOf(address(e.beekeeper())), 100 ether, "fee");
        assertEq(e.beekeeper().lastFees(), 100 ether, "distributed");
    }
}
