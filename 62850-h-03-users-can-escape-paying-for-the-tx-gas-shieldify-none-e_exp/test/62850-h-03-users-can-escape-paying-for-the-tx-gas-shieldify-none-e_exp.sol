// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {ERC20, Exploit, GasTankFixed} from "./62850-h-03-users-can-escape-paying-for-the-tx-gas-shieldify-none-e.sol";

contract Finding62850Test is Test {
    function test_withdraw_escapes_the_sponsored_gas() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.token().balanceOf(address(e)), 1000 ether, "user holds the full 1000");
        assertEq(e.tank().balances(e.feeReceiver()), 0, "fee receiver was not paid");
        assertEq(e.tank().sponsored(address(e)), 1000 ether, "sponsorship still unpaid");
        assertEq(e.tank().balances(address(e)), 0, "nothing left to repay");
    }

    function test_control_paused_withdraw_lets_the_owner_repay() public {
        ERC20 token = new ERC20();
        address feeReceiver = address(0xFE);
        GasTankFixed tank = new GasTankFixed(token, feeReceiver);
        token.mint(address(this), 1000 ether);
        token.approve(address(tank), 1000 ether);
        tank.deposit(1000 ether);
        tank.postOp(address(this), 1000 ether);
        vm.expectRevert(bytes("withdraw paused"));
        tank.gasTankWithdraw(1000 ether);
        tank.repaySponsoredTransaction(address(this), 1000 ether);
        assertEq(tank.balances(feeReceiver), 1000 ether, "fee receiver is credited");
        assertEq(token.balanceOf(address(this)), 0, "user could not pull the tokens back");
        assertEq(tank.sponsored(address(this)), 0, "debt cleared");
    }
}
