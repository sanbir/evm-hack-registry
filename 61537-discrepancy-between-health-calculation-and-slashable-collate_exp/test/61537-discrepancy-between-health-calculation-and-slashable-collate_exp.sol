// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;
import "forge-std/Test.sol";
import {Exploit} from "./61537-discrepancy-between-health-calculation-and-slashable-collate.sol";

contract Finding61537Test is Test {
    function test_rescue_deposit_is_not_slashable() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.covered(), 1100 ether, "coverage");
        assertEq(e.slashable(), 100 ether, "slashable");
        assertEq(e.badDebt(), 900 ether, "bad debt");
        assertEq(e.usd().balanceOf(address(e)), 1000 ether, "borrower keeps loan");
        assertEq(e.col().balanceOf(address(e)), 1000 ether, "fresh collateral returned");
    }
}
