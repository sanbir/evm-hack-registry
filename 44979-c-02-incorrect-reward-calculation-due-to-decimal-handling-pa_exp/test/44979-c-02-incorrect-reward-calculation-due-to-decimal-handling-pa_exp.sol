// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, SDai, DSRStrategyFixed, DepositUSDFixed, Victim} from
    "./44979-c-02-incorrect-reward-calculation-due-to-decimal-handling-pa.sol";

contract Finding44979Test is Test {
    function test_exploit_late_depositor_gets_1_share_and_early_redeems_both() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.vault().balanceOf(address(e.victim())), 1, "late has 1 share");
        assertEq(e.vault().sharePrice(), 1, "share price collapsed");
        uint256 one = 1 ether;
        uint256 both = (2 * one) * one / (one + 1);
        assertEq(e.token().balanceOf(address(e)), both, "early took both");
        assertEq(e.token().balanceOf(address(e.vault())), 2, "2 wei dust");
        assertGt(e.token().balanceOf(address(e)), 1 ether, "early profit");
    }

    function test_control_divide_by_1e18_gives_the_late_depositor_a_full_share() public {
        SDai token = new SDai();
        DSRStrategyFixed strategy = new DSRStrategyFixed(token);
        DepositUSDFixed vault = new DepositUSDFixed(token, strategy);
        Victim victim = new Victim();
        token.mint(address(this), 1 ether);
        token.approve(address(vault), 1 ether);
        uint256 earlyShares = vault.deposit(1 ether);
        vault.updateRewards();
        assertEq(vault.sharePrice(), 1 ether, "price stays 1");

        token.mint(address(victim), 1 ether);
        victim.depositFixed(vault, token, 1 ether);
        assertEq(vault.balanceOf(address(victim)), 1 ether, "late full share");

        uint256 got = vault.withdraw(earlyShares);
        assertEq(got, 1 ether, "early withdraws only their deposit");
        assertEq(token.balanceOf(address(this)), 1 ether, "early whole");
        assertEq(token.balanceOf(address(vault)), 1 ether, "late deposit remains");
    }
}
