// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, OracleFixed} from "./65739-h-11-cumulativeprice-is-corrupted-when-price-updates-are-rej.sol";

contract Finding65739Test is Test {
    function test_exploit_rejected_update_leaves_40000() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.oracle().cumulativePrice(), 40000, "corrupted cumulative");
        assertEq(e.marker().balanceOf(e.SINK()), 10000, "extra 10000");
    }

    function test_control_rejected_update_lands_on_30000() public {
        OracleFixed oracle = new OracleFixed();
        assertFalse(oracle.updatePrice(100, 200, 10), "200 is outside 10 percent");
        assertEq(oracle.cumulativePrice(), 10000, "rejected update writes nothing");
        assertTrue(oracle.updatePrice(200, 105, 10), "105 is accepted");
        assertEq(oracle.cumulativePrice(), 30000, "honest cumulative");
    }
}
