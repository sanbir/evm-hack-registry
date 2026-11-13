// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, PenguinManager, FixedPenguinManager, PengToken} from
    "./57908-h-02-user-can-be-permanently-denied-from-purchasing-new-peng.sol";

contract Finding57908Test is Test {
    function test_exploit_cannot_spend_100() public {
        Exploit e = new Exploit();
        uint256 beforeBal = e.peng().balanceOf(address(this));
        e.run();

        assertEq(e.manager().aliveCount(address(e)), 1, "one alive");
        assertEq(e.manager().ownedCount(address(e)), 2, "two owned");
        assertEq(e.peng().balanceOf(address(this)) - beforeBal, 100e18, "100 unspent");
        assertEq(e.fixedManager().aliveCount(address(e)), 2, "control alive 2");
        assertEq(e.peng().balanceOf(address(e.fixedManager())), 300e18, "control spent 300");
    }

    function test_control_third_buy_spends_100() public {
        PengToken peng = new PengToken();
        FixedPenguinManager fixedManager = new FixedPenguinManager(peng, 2);
        peng.mint(address(this), 300e18);
        peng.approve(address(fixedManager), type(uint256).max);
        fixedManager.buyPenguin(address(this));
        fixedManager.buyPenguin(address(this));
        fixedManager.killPenguin(address(this));
        fixedManager.buyPenguin(address(this));
        assertEq(fixedManager.aliveCount(address(this)), 2, "two alive");
        assertEq(peng.balanceOf(address(this)), 0, "300 spent");
        assertEq(peng.balanceOf(address(fixedManager)), 300e18, "manager holds 300");
    }
}
