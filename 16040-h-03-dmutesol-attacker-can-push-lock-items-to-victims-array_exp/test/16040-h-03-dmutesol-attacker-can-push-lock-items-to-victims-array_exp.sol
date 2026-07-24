// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./16040-h-03-dmutesol-attacker-can-push-lock-items-to-victims-array.sol";

contract DMuteLockDosTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();

        assertGt(e.extrapolatedGas(), e.ZK_BLOCK_GAS(), "exceeds zkSync block gas");
        assertEq(e.victimLocks(), 1 + e.SAMPLE(), "array inflated");
        assertGt(e.sampleGas(), 0, "sample measured");
    }
}
