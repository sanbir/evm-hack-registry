// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;
import "forge-std/Test.sol";
import {Exploit} from "./44296-incorrect-handling-of-negative-multipliers-in-quantammweight.sol";

contract Finding44296Test is Test {
    function test_negative_multiplier_reverts_swap() public {
        vm.warp(1784893842);
        Exploit e = new Exploit();
        e.run();
        assertTrue(e.swapFailed(), "swap failed");
        assertLt(e.fixedWeight(), 0.15e18, "fixed weight fell");
        assertGt(e.fixedWeight(), 0, "fixed stays positive");
    }
}
