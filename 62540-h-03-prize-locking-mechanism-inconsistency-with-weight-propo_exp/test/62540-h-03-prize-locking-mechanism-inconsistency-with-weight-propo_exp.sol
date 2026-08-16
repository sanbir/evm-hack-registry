// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;
import "forge-std/Test.sol";
import {Exploit, SpinLottery, MarkerToken} from "./62540-h-03-prize-locking-mechanism-inconsistency-with-weight-propo.sol";
contract Finding62540Test is Test {
    function test_prizeLockWeightMismatch_dos() public {
        Exploit e = new Exploit();
        e.run();
        emit log_named_uint("stuck spinCost", e.spinCost());
        assertTrue(e.settlementReverted(), "higher-rarity spin cannot settle (DoS)");
        assertEq(e.controlRarity(), 1, "control settles");
    }
}
