// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./16039-h-02-attacker-can-front-run-bond-buyer-and-make-them-buy-it.sol";

contract MuteBondFrontRunTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();

        assertLe(e.actualPrice() * 100, e.expectedPrice() * 70, "price should fall by at least 30%");
        assertLt(e.victimPayout(), e.expectedPayout(), "victim payout should be lower");
        assertGt(e.payoutLoss(), 0, "victim loss should be positive");
    }

    function test_control_without_front_run() public {
        MockERC20 lp = new MockERC20();
        MockERC20 mute = new MockERC20();
        MuteBond bond = new MuteBond(lp, mute);
        bond.advance(7 days);
        uint256 expected = bond.payoutFor(10 ether);
        lp.mint(address(this), 10 ether);
        lp.approve(address(bond), type(uint256).max);
        uint256 before = mute.balanceOf(address(this));
        bond.deposit(10 ether, address(this), false);
        assertEq(mute.balanceOf(address(this)) - before, expected, "no front-run should preserve quote");
    }
}
