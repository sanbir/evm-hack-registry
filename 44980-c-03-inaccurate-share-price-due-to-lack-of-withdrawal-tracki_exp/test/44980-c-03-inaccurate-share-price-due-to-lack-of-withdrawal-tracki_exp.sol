// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Token, DepositETH, DepositETHFixed, Carol} from
    "./44980-c-03-inaccurate-share-price-due-to-lack-of-withdrawal-tracki.sol";

contract Finding44980Test is Test {
    function test_exploit_carol_is_underpaid_and_rewards_stick() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.aliceOut(), 1050000000000000001, "alice rounded withdraw");
        assertEq(e.carolOut(), 1024390243902439024, "carol got 1.024 not 1.05");
        assertEq(e.vault().ethWithdrawn(), 0, "ethWithdrawn never moved");
        assertGt(e.vault().nETHMinted(), 0, "exited shares still counted");
        uint256 stuck = e.token().balanceOf(address(e.vault()));
        assertEq(stuck, (1e18 + 5e16) - e.carolOut(), "stuck rewards");
        assertEq(e.token().balanceOf(address(e.carol())), e.carolOut(), "carol balance");
    }

    function test_control_tracking_withdrawals_pays_carol_the_full_reward() public {
        Token token = new Token();
        DepositETHFixed vault = new DepositETHFixed(token);
        Carol carol = new Carol();
        uint256 one = 1e18;
        uint256 reward = 5e16;

        token.mint(address(this), one);
        token.approve(address(vault), one);
        vault.deposit(one);
        vault.earn(reward);
        token.mint(address(vault), 1);
        uint256 aliceOut = vault.withdraw(vault.sharesOf(address(this)));

        token.mint(address(carol), one);
        carol.approveAndDepositFixed(vault, token, one);
        vault.earn(reward);
        uint256 carolOut = carol.withdrawAllFixed(vault);

        assertEq(aliceOut, 1050000000000000001, "alice still rounds");
        // Alice's rounded withdraw consumed the 1 wei dust, so Carol receives the
        // remaining 1.05 ETH minus that wei and the vault is empty.
        assertEq(carolOut, one + reward - 1, "carol receives the remaining rewards");
        assertEq(token.balanceOf(address(vault)), 1, "only the donated rounding wei remains");
        assertGt(vault.ethWithdrawn(), 0, "withdrawals recorded");
    }
}
