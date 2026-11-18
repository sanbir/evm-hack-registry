// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Token, RewardVaultFixed, AegisVault} from
    "./41319-c-01-dos-attack-on-aegis-vault-when-staking-is-enabled-pasho.sol";

contract Finding41319Test is Test {
    function test_exploit_delegated_wei_freezes_vault_exit() public {
        Exploit e = new Exploit();
        e.run();

        assertTrue(e.exitFailed(), "exit reverted");
        assertEq(e.locked(), 1000 ether + 1, "1000 plus 1 wei stuck");
        assertEq(e.token().balanceOf(address(e.rewards())), 1000 ether + 1, "reward vault holds both");
        assertEq(e.rewards().balanceOf(address(e.aegis())), 1000 ether + 1, "account still staked");
        assertEq(e.token().balanceOf(address(e.aegis())), 0, "vault recovered nothing");
    }

    function test_control_exit_withdraws_only_self_stake() public {
        Token token = new Token();
        RewardVaultFixed rewards = new RewardVaultFixed(token);
        AegisVault aegis = new AegisVault(token, rewards);
        token.mint(address(aegis), 1000 ether);
        token.mint(address(this), 1);

        aegis.stakeSelf(1000 ether);
        token.approve(address(rewards), 1);
        rewards.delegateStake(address(aegis), 1);

        bool ok = aegis.tryExit();
        assertTrue(ok, "fixed exit succeeds");
        assertFalse(aegis.exitFailed(), "not failed");
        assertEq(token.balanceOf(address(aegis)), 1000 ether, "vault recovered self stake");
        assertEq(rewards.balanceOf(address(aegis)), 1, "only the delegated wei remains");
        assertEq(token.balanceOf(address(rewards)), 1, "delegated wei still escrowed");
    }
}
