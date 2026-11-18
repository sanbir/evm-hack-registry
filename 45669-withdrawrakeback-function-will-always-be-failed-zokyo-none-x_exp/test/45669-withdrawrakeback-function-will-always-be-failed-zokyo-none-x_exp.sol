// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";

import {Exploit, XyroTokenFixed, TreasuryFixed} from "./45669-withdrawrakeback-function-will-always-be-failed-zokyo-none-x.sol";
contract Finding45669Test is Test {
    function test_exploit_withdraw_reverts_and_rakeback_stays() public {
        Exploit e = new Exploit();
        e.run();
        assertTrue(e.claimReverted());
        assertEq(e.token().balanceOf(address(e)), 0);
        assertEq(e.earnedAfter(), 1000 ether);
    }
    function test_control_returning_mint_pays_1000() public {
        XyroTokenFixed token = new XyroTokenFixed();
        TreasuryFixed treasury = new TreasuryFixed(token);
        treasury.credit(address(this), 1000 ether);
        treasury.withdrawRakeback(1000 ether);
        assertEq(token.balanceOf(address(this)), 1000 ether);
        assertEq(treasury.earnedRakeback(address(this)), 0);
    }
}
