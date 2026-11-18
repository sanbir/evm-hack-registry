// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit} from "./58381-h-12-incorrect-lend-reward-distribution-for-cross-chain-borr.sol";
contract Finding58381Test is Test {
    function test_bob_is_paid_and_alice_is_not() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.bobLend(), 10000e18);
        assertEq(e.aliceLend(), 0);
        assertEq(e.lend().balanceOf(address(e)), 10000e18);
    }
}
