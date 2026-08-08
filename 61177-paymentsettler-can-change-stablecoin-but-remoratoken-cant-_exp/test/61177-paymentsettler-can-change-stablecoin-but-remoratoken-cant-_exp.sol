// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {Exploit, Fixed, MiniToken} from "./61177-paymentsettler-can-change-stablecoin-but-remoratoken-cant-.sol";

contract PoC_61177 is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    uint256 internal constant EXPECTED = 100e18;

    function test_exploit_stablecoin_mismatch_dos() external {
        Exploit e = new Exploit();
        e.run();

        // The core transfer-with-fee function was DoS'd by the stablecoin mismatch.
        assertTrue(e.dosOccurred(), "core function should revert (DoS)");
        assertEq(e.blockedAmount(), EXPECTED, "blocked transfer amount");

        // Marker records the magnitude of the blocked transfer at SINK.
        MiniToken marker = e.marker();
        assertEq(marker.balanceOf(SINK), EXPECTED, "DoS marker magnitude at SINK");
    }

    function test_control_fixed_keeps_stablecoin_in_sync() external {
        Fixed f = new Fixed();
        f.run();

        // With the fix, RemoraToken reads the settler's live stablecoin, so the
        // same admin action does not break the core function.
        assertTrue(f.transferSucceeded(), "fixed transfer should succeed");
        assertEq(f.blockedAmount(), 0, "no transfer blocked under fix");
    }
}
