// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit} from "./49434-arbitrary-call-in-lendingpoolrebalance-leads-to-asset-theft.sol";

contract Finding49434Test is Test {
    function test_exploit_quote_call_then_swap_steals_weth() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.weth().balanceOf(address(this)), 5 ether, "attacker has the supplied WETH");
        assertEq(e.weth().balanceOf(address(e.pool())), 0, "pool empty");
        assertEq(e.weth().balanceOf(address(e.uni())), 0, "integration empty");
        assertEq(e.pool().decodedOut(), 0, "decoded amount is 0");
    }
}
