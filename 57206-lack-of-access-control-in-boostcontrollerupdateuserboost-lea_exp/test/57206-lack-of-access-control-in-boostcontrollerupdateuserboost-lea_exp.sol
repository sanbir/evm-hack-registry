// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Token, Alice, BoostControllerFixed} from
    "./57206-lack-of-access-control-in-boostcontrollerupdateuserboost-lea.sol";

contract Finding57206Test is Test {
    function test_exploit_overwrites_alice_boost_and_takes_rewards() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.attackerReward(), 1000 ether, "attacker pool paid");
        assertFalse(e.aliceDelegated(), "alice cannot delegate");
        assertEq(e.reward().balanceOf(e.POOL_A()), 0, "chosen pool got 0");
        assertEq(e.controller().delegatedPool(address(e.alice())), address(e), "forced pool");
    }

    function test_control_only_alice_can_direct_her_boost() public {
        Token ve = new Token("veRAAC");
        Token reward = new Token("RAAC");
        BoostControllerFixed controller = new BoostControllerFixed(ve, reward);
        Alice alice = new Alice();
        address poolA = address(uint160(0xA11A));
        address attacker = address(uint160(0xBAD));
        controller.support(poolA);
        controller.support(attacker);
        ve.mint(address(alice), 1000 ether);
        vm.expectRevert(bytes("auth"));
        controller.updateUserBoost(address(alice), attacker);
        alice.delegateFixed(controller, poolA);
        reward.mint(address(controller), 1000 ether);
        controller.payRewards(poolA, attacker);

        assertEq(reward.balanceOf(poolA), 1000 ether, "alice pool paid");
        assertEq(reward.balanceOf(attacker), 0, "attacker got 0");
        assertEq(controller.delegatedPool(address(alice)), poolA, "alice chose");
    }
}
