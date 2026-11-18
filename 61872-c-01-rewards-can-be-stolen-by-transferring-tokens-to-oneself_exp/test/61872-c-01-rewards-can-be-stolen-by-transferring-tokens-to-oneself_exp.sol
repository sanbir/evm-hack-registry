// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit} from "./61872-c-01-rewards-can-be-stolen-by-transferring-tokens-to-oneself.sol";

contract Finding61872Test is Test {
    function test_exploit_self_transfer_takes_the_reward_pot() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.attackerEffective(), e.totalEffective(), "attacker effective equals total");
        assertEq(e.attackerEffective(), 200 ether, "effective doubled to 200");
        assertEq(e.reward().balanceOf(address(this)), 140 ether, "attacker took 140");
        assertEq(e.victimReward(), 0, "honest staker got 0");
        assertEq(e.staking().effectiveOf(address(e.victim())), 100 ether, "victim weight still recorded");
    }
}
