// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit} from "./58388-h-19-cross-chain-liquidation-uses-collateral-seize-amount-in.sol";

contract Finding58388Test is Test {
    function test_debt_falls_by_the_seize_not_the_repay() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.router().cashIn(), 100 ether, "repay");
        assertEq(e.router().debtReducedBy(), 150 ether, "booked the seize");
        assertEq(e.router().borrowerDebt(), 50 ether, "debt left");
        assertEq(e.gap(), 50 ether, "lenders short 50");
    }
}
