// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./27454-owner-of-a-bad-shortrecord-can-front-run-flagshort-calls-and.sol";

contract DittoFrontrunFlagShortTest is Test {
    function test_FrontrunFlagShortAndLiquidateSecondary() public {
        Exploit e = new Exploit();
        e.run();

        assertFalse(e.bobFlagAttempt1Succeeded());
        assertFalse(e.bobLiquidateAttemptSucceeded());
        assertFalse(e.bobFlagAttempt2Succeeded());
    }

    /// @dev Control: WITHOUT the front-running transfer, flagShort correctly
    ///      succeeds against a genuinely still-Active ShortRecord — proving
    ///      the block is specifically caused by the transfer invalidating
    ///      the id, not by flagShort being broken outright.
    function test_Control_NoFrontrun_FlagSucceeds() public {
        ShortRecordManager sm = new ShortRecordManager();
        Actor alice = new Actor(sm);
        Actor bob = new Actor(sm);

        uint256 shortId = alice.createShort(500, 1000);
        alice.mintNFT(shortId);
        // no transfer this time

        sm.flagShort(address(alice), shortId); // succeeds - short is genuinely still Active
        (, , , uint256 flaggerId, ShortRecordManager.Status status) = sm.shortRecords(shortId);
        assertEq(uint8(status), uint8(ShortRecordManager.Status.Active));
        assertTrue(flaggerId != 0, "flag should have been recorded");
    }
}
