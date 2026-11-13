// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    RewardToken,
    VaultETH_V2Fixed
} from "./37230-function-rm-updatereward-in-vaulteth-v2-has-no-access-contro.sol";

contract Finding37230Test is Test {
    function test_exploit_anyone_sets_reward_and_claims_the_vault() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.taken(), 1000 ether, "1000 reward tokens claimed");
        assertEq(e.rewardToken().balanceOf(address(e)), 1000 ether, "attacker balance");
        assertEq(e.rewardToken().balanceOf(address(e.vault())), 0, "vault empty");
        assertTrue(address(this) != e.riskManager(), "caller is not the risk manager");
    }

    function test_control_risk_manager_check_reverts() public {
        RewardToken token = new RewardToken();
        VaultETH_V2Fixed vault = new VaultETH_V2Fixed(token, address(0xBEEF));
        token.mint(address(vault), 1000 ether);
        vm.expectRevert(bytes("risk"));
        vault.RM_UpdateReward(1000 ether);
        assertEq(vault.reward(), 0, "reward unchanged");
        assertEq(token.balanceOf(address(vault)), 1000 ether, "tokens stay");
    }
}
