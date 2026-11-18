// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Token, CdsPoolFixed} from "./45460-h-7-incorrect-deducted-cds-deposit-amount-in-withdrawuser-sh.sol";

contract Finding45460Test is Test {
    function test_exploit_withdraw_pays_900() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.paid(), 900 ether, "paid 900");
        assertEq(e.totalAfter(), 800 ether, "total fell to 800");
        assertEq(e.victimShort(), 200 ether, "other depositor short 200");
    }

    function test_control_withdraw_pays_left_deposit() public {
        Token asset = new Token("CDS");
        CdsPoolFixed pool = new CdsPoolFixed(asset);
        pool.open(address(this), 1000 ether, 400 ether, 100 ether);
        pool.open(address(0xBEEF), 1000 ether, 0, 0);
        asset.mint(address(pool), 1700 ether);
        pool.withdrawUser(address(this));
        assertEq(asset.balanceOf(address(this)), 700 ether, "pays the 700 left");
        assertEq(pool.totalCdsDepositedAmount(), 1000 ether, "other depositor remains");
        assertEq(asset.balanceOf(address(pool)), 1000 ether, "cash covers the other deposit");
    }
}
