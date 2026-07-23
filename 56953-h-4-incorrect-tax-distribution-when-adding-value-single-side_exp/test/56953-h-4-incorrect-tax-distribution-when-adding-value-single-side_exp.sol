// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./56953-h-4-incorrect-tax-distribution-when-adding-value-single-side.sol";

contract TaxDilutionTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();
        assertGt(e.bobGot(), 0, "bob captured share of own tax");
        assertLt(e.aliceGot(), e.taxPaid(), "alice diluted");
        assertGe(e.dilutedAway(), e.taxPaid() / 2, "material dilution");
    }
}
