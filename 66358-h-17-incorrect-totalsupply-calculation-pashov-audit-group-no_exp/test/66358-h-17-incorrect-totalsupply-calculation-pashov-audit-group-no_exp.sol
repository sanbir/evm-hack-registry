// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit} from "./66358-h-17-incorrect-totalsupply-calculation-pashov-audit-group-no.sol";
contract Finding66358Test is Test {
    function test_inflated_supply_is_borrowed() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.rToken().totalSupply(), 400e18);
        assertEq(e.rToken().fairClaims(), 300e18);
        assertEq(e.taken(), 100e18);
        assertEq(e.asset().balanceOf(address(e)), 100e18);
        assertEq(e.asset().balanceOf(address(e.book())), 200e18);
    }
}
