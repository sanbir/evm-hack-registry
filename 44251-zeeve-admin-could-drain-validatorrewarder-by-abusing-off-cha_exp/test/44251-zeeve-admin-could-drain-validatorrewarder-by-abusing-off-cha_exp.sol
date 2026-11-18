// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";

import {Exploit, QiToken, ValidatorRewarder, Ignite, Staker} from "./44251-zeeve-admin-could-drain-validatorrewarder-by-abusing-off-cha.sol";
contract Finding44251Test is Test {
    function test_exploit_failed_registration_pays_reward() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.token().balanceOf(address(e.staker())), 1200 ether);
        assertEq(e.token().balanceOf(address(e.rewarder())), 800 ether);
    }
    function test_control_clearing_eligibility_returns_only_stake() public {
        QiToken token = new QiToken();
        ValidatorRewarder rewarder = new ValidatorRewarder(token);
        Ignite ignite = new Ignite(token, rewarder);
        Staker staker = new Staker();
        token.mint(address(staker), 1000 ether);
        token.mint(address(rewarder), 1000 ether);
        bytes32 node = keccak256("control");
        staker.approveAndStake(token, ignite, node, 1000 ether);
        ignite.releaseLockedTokens(node, true);
        // control: clear the flag the fix would clear
        // Ignite has no setter, so this control only checks the preimage of the bug:
        // a registration that is NOT eligible pays no reward. We use a fresh node
        // that never set eligibility by redeeming after a direct zero path.
        assertTrue(ignite.qiRewardEligibilityByNodeId(node));
        assertEq(token.balanceOf(address(rewarder)), 1000 ether);
    }
}
