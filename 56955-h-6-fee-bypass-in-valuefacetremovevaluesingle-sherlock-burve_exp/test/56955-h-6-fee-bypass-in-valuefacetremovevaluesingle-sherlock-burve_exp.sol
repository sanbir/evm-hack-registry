// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Token, Closure, ValueFacetFixed} from
    "./56955-h-6-fee-bypass-in-valuefacetremovevaluesingle-sherlock-burve.sol";

contract Finding56955Test is Test {
    function test_single_removal_pays_1000_and_records_no_fee() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.chargedTax(), 0, "realTax is 0");
        assertEq(e.fairTax(), 100 ether, "10% of 1000");
        assertEq(e.closure().earnings(), 0, "protocol earnings");
        assertEq(e.received(), 1_000 ether, "user received the gross amount");
        assertEq(e.token().balanceOf(address(e)), 1_000 ether, "balance");
    }

    function test_control_realRemoved_keeps_100_fee() public {
        Token token = new Token();
        Closure closure = new Closure();
        ValueFacetFixed fixedFacet = new ValueFacetFixed(token, closure);
        token.mint(address(fixedFacet), 1_000 ether);
        uint256 got = fixedFacet.removeValueSingle(address(this), 0);
        assertEq(got, 900 ether, "user net of fee");
        assertEq(closure.earnings(), 100 ether, "protocol kept 100");
        assertEq(token.balanceOf(address(fixedFacet)), 100 ether, "fee stayed in the facet");
    }
}
