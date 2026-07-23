// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./55706-h-04-unwrapping-while-equating-inside-the-eq-function-fails.sol";

contract H04Exp is Test {
    uint256 constant PACKED_L = 57397893746390593330843002609134450905171641873901357473538499055192046043136;
    uint256 constant PACKED_M = 57634551253070896831007164474234001986302524716082690413926794286165257093120;

    function test_h04_eq_ignores_dual_encoding() public {
        Exploit e = new Exploit();
        e.run();

        VulnerableFloat128 lib = e.lib();
        packedFloat a = packedFloat.wrap(PACKED_L);
        packedFloat b = packedFloat.wrap(PACKED_M);
        assertFalse(lib.eq(a, b), "eq must fail on dual encodings of 1.0");

        (int256 m1, int256 e1) = lib.decode(a);
        (int256 m2, int256 e2) = lib.decode(b);
        // Both represent 1.0
        assertEq(m1, int256(10 ** 71));
        assertEq(e1, -71);
        assertEq(m2, int256(10 ** 37));
        assertEq(e2, -37);
    }
}
