// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, CheckerFixed} from "./65730-h-02-variable-overwrite-in-checkpoolandgetcenterprice-create.sol";

contract Finding65730Test is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    function test_exploit_deviation_is_zero() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.checker().lastDeviation(), 0, "deviation 0");
        assertTrue(e.checker().accepted(), "gap accepted");
        assertEq(e.marker().balanceOf(SINK), 100 ether, "gap was 100");
    }

    function test_control_reports_the_spot_gap() public {
        uint256 gap = new CheckerFixed().check(100 ether, 200 ether);
        assertEq(gap, 100 ether, "spot 100 against twap 200");
    }
}
