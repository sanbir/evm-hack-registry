// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Exploit, Token, LidoStrategy, DepositETHFixed, Victim} from
    "./44986-h-06-share-price-manipulation-pashov-audit-group-none-nexus.sol";

contract Finding44986Test is Test {
    function test_exploit_zero_share_price_locks_100_steth() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.price(), 0, "price is 0");
        assertEq(e.victimShares(), 0, "no shares");
        assertTrue(e.withdrawBlocked(), "withdraw blocked");
        assertEq(e.stuck(), 100 ether + 100, "strategy holds the deposit");
        assertEq(e.token().balanceOf(address(e.strategy())), 100 ether + 100, "balance");
    }

    function test_control_keeps_share_price_when_no_shares_exist() public {
        Token token = new Token();
        LidoStrategy strategy = new LidoStrategy(address(token));
        DepositETHFixed fixedVault = new DepositETHFixed(strategy, token);
        Victim victim = new Victim();
        token.mint(address(this), 100);
        token.transfer(address(strategy), 100);
        fixedVault.updateRewards();
        token.mint(address(victim), 100 ether);
        victim.depositFixed(fixedVault, token, 100 ether);

        assertEq(fixedVault.sharePrice(), 1e18, "price stays 1e18");
        assertEq(fixedVault.shares(address(victim)), 100 ether, "full shares");
        uint256 got = victim.withdrawFixed(fixedVault, 100 ether);
        assertGe(got, 100 ether, "victim recovered the deposit");
        assertEq(token.balanceOf(address(strategy)), 0, "strategy empty");
    }
}
