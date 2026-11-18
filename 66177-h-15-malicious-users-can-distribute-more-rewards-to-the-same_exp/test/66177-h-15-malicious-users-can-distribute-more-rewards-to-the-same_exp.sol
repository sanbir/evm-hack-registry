// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit} from "./66177-h-15-malicious-users-can-distribute-more-rewards-to-the-same.sol";

contract Finding66177Test is Test {
    function test_same_gauge_is_paid_twice_in_one_cycle() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.token().balanceOf(address(e.gaugeA())), 75 ether, "A took 75");
        assertEq(e.token().balanceOf(address(e.gaugeB())), 25 ether, "B left 25");
    }
}
