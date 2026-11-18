// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit} from "./41349-c-01-uniswap-v3-launch-can-be-enabled-without-raising-enough.sol";

contract Finding41349Test is Test {
    function test_exploit_launch_takes_15_eth_from_the_other_token() public {
        Exploit e = new Exploit();
        e.run();
        assertTrue(e.factory().launched(), "launched");
        assertEq(e.eth().balanceOf(address(e.pool())), 835 ether, "pool funded for 835");
        assertEq(e.factory().otherRaised(), 5 ether, "other reserve lost 15");
        assertEq(e.factory().raised(1), 0, "this raise was consumed");
        assertEq(e.factory().sold(1), 820, "only 820 tokens were sold");
    }
}
