// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Token, EarnVaultFixed} from
    "./46433-donated-reward-token-can-overflow-the-yieldaccumulator-and-r.sol";

contract Finding46433Test is Test {
    function test_exploit_donated_reward_overflows_uint151_and_locks_deposit() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.shares(), 999, "shares");
        assertEq(e.accum(), e.REPORTED_ACCUM(), "accum");
        assertTrue(e.withdrawReverted(), "reverted");
        assertEq(e.asset().balanceOf(address(e)), 0, "user");
        assertEq(e.locked(), 2 ether, "vault");
    }

    function test_control_first_deposit_ignores_donation_and_withdraws() public {
        Token asset = new Token("ASSET");
        Token reward = new Token("RWD");
        EarnVaultFixed vault = new EarnVaultFixed(asset, reward);
        vault.donateAsset(1 ether);
        asset.mint(address(this), 1 ether);
        asset.approve(address(vault), 1 ether);
        vault.deposit(1 ether);
        assertEq(vault.sharesOf(address(this)), 1000 ether, "shares");
        vault.donateReward(1 ether + 100_000);
        assertLe(vault.previewRewardAccum(), 2 ** 151 - 1, "fits");
        vault.withdraw();
        assertEq(asset.balanceOf(address(this)), 1 ether, "back");
        assertEq(vault.deposited(address(this)), 0, "cleared");
    }
}
