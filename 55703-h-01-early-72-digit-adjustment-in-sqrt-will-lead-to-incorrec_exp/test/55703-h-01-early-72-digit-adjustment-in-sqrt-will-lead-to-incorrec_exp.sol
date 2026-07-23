// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./55703-h-01-early-72-digit-adjustment-in-sqrt-will-lead-to-incorrec.sol";

contract H01Exp is Test {
    function test_h01_sqrt_exponent_off_by_one() public {
        Exploit e = new Exploit();
        e.run();

        // Re-assert harm on public state / return path.
        VulnerableSqrt v = e.v();
        uint256 aMan = 3820000000000000000000000000000000000000000000000000000000000000000000000;
        int256 aExp = 2266;
        (uint256 buggyMan, int256 buggyOff,) = v.sqrtLargePath(aMan, aExp);
        (uint256 fixedMan, int256 fixedOff,) = v.sqrtLargePathFixed(aMan, aExp);
        assertEq(buggyMan, fixedMan);
        assertEq(buggyOff + 1, fixedOff, "buggy exponent is one less than fixed");
        assertEq(int256(buggyOff) - 8192, 1097);
        assertEq(int256(fixedOff) - 8192, 1098);
    }
}
