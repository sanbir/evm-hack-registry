// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {
    Exploit,
    RewardSource,
    RewardToken,
    VaultRewarderFixed
} from "./35119-h-6-loss-of-rewards-due-to-continuous-griefing-attacks-on-l2.sol";

contract Finding35119Test is Test {
    address internal constant USER = 0x2222222222222222222222222222222222222222;

    function test_grief_pays_the_user_zero_of_n() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.userGot(), 0, "user received 0");
        assertEq(e.token().balanceOf(USER), 0, "user balance");
        assertEq(e.token().balanceOf(address(e.vault())), 9900, "N stuck");
        assertEq(e.vault().accumulated(), 0, "index stayed 0");

        console2.log("user got", e.userGot());
        console2.log("stuck", e.token().balanceOf(address(e.vault())));
    }

    function test_control_remainder_lets_the_user_claim_n() public {
        RewardToken token = new RewardToken();
        RewardSource source = new RewardSource(token, 99);
        VaultRewarderFixed vault = new VaultRewarderFixed(token, source);
        token.mint(address(source), 9900);
        vault.deposit(USER, 100);

        for (uint256 i = 0; i < 100; i++) {
            vault.claimRewardTokens();
        }
        uint256 got = vault.claim(USER);

        assertEq(got, 9900, "user receives N");
        assertEq(token.balanceOf(USER), 9900, "balance");
        assertEq(token.balanceOf(address(vault)), 0, "vault emptied");
        assertEq(vault.accumulated(), 99, "index");

        console2.log("control user got", got);
        console2.log("control vault left", token.balanceOf(address(vault)));
    }
}
