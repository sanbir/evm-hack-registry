// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {Exploit} from "./56952-burve-incorrect-netting-logic-leads-to-excessive-withdrawal-amounts.sol";

contract Burve56952Test is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    function test_incorrectNettingExcessiveWithdrawal() public {
        Exploit e = new Exploit();
        e.run();

        // commit() withdrew the FULL pending amount instead of the net amount:
        // the netting branch was a no-op because `assetsToDeposit` was zeroed
        // before being subtracted.
        assertEq(e.actualWithdrawn(), 300e18, "should withdraw full, not net");
        assertEq(e.correctNet(), 200e18, "net amount reference");
        assertEq(e.excessWithdrawn(), 100e18, "excess pulled from shared vault");
        assertEq(e.sharesDecrement(), 300e18, "totalVaultShares over-decremented");

        // Concrete harm magnitude: 100e18 of shared-vault assets over-withdrawn.
        assertEq(e.marker().balanceOf(SINK), 100e18, "harm measured at sink");
    }
}
