// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";

import {Exploit, UltiToken, Distributor} from "./43912-h-01-wrong-active-pumper-bonus-calculation-pashov-audit-grou.sol";
contract Finding43912Test is Test {
    function test_exploit_bonus_is_297_short() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.distributor().lastPaid(), 10003 ether);
        assertEq(e.shortfall(), 297 ether);
        assertEq(e.token().balanceOf(address(e.pumper())), 10003 ether);
        assertEq(e.token().balanceOf(address(e.distributor())), 297 ether);
    }
    function test_control_percent_denominator_pays_10300() public {
        UltiToken token = new UltiToken();
        uint256 base = 10000 ether;
        uint256 paid = base * (100 + 3) / 100;
        assertEq(paid, 10300 ether);
        token.mint(address(this), paid);
        assertEq(token.balanceOf(address(this)), 10300 ether);
    }
}
