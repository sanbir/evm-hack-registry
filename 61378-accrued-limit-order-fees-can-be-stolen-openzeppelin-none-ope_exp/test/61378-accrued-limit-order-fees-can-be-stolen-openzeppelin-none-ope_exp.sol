// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {
    Exploit,
    LimitOrderFixed,
    Token
} from "./61378-accrued-limit-order-fees-can-be-stolen-openzeppelin-none-ope.sol";

contract Finding61378Test is Test {
    function test_exploit_takes_90_of_the_accrued_fees() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.attackerGot(), 90 ether, "attacker share");
        assertEq(e.honestGot(), 10 ether, "honest share");
        assertEq(e.feeToken().balanceOf(address(e)), 90 ether);
        assertEq(e.feeToken().balanceOf(e.honest()), 10 ether);
    }

    function test_control_snapshot_pays_the_earlier_lp() public {
        Token feeToken = new Token("Fee", "FEE", 18);
        LimitOrderFixed book = new LimitOrderFixed(feeToken);
        address honest = address(0xA11CE);
        book.place(honest, 10 ether);
        feeToken.mint(address(this), 100 ether);
        feeToken.approve(address(book), 100 ether);
        book.accrue(100 ether);
        book.place(address(this), 90 ether);
        book.crossTick();
        uint256 attackerGot = book.withdraw(address(this));
        uint256 honestGot = book.withdraw(honest);
        assertEq(attackerGot, 0, "new liquidity earned old fees");
        assertEq(honestGot, 100 ether, "honest LP missed the accrued fees");
        assertEq(feeToken.balanceOf(honest), 100 ether);
    }
}
