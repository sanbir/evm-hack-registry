// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Exploit} from "./13297-collateralizationoracle-fei-in-excluded-deposits-contributes.sol";

contract Finding13297Test is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    function test_exploit_excluded_fei_counts_as_circulating() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.stats().userCirculatingFei(), 6_000 ether, "circ");
        assertEq(e.stats().protocolControlledValue(), 6_000 ether, "pcv");
        assertEq(e.stats().protocolEquity(), 0, "equity");
        assertEq(e.gap(), 3_000 ether, "gap");
        assertEq(e.marker().balanceOf(SINK), 3_000 ether, "marker");
        console2.log("buggy circulating");
        console2.log(e.stats().userCirculatingFei());
        console2.log("fair circulating");
        console2.log(e.fairCirc());
        console2.log("overstatement");
        console2.log(e.gap());
    }

    function test_control_excluded_fei_is_not_user_circulating() public {
        Exploit e = new Exploit();
        (uint256 circ, int256 equity) = e.stats().pcvStatsFixed();
        assertEq(circ, 3_000 ether, "circ");
        assertEq(equity, int256(3_000 ether), "equity");
        assertEq(e.marker().balanceOf(SINK), 0, "no marker");
        assertEq(e.fei().totalSupply(), 10_000 ether, "supply");
    }
}
