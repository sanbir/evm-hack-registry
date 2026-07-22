// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./34176-h-06-closing-a-sr-during-a-wrong-redemption-proposal-leads-t.sol";

contract DittoDisputeClosedSRTest is Test {
    function test_disputingAClosedShortRecordPermanentlyLocksCollateral() public {
        Exploit e = new Exploit();
        e.run();

        Vulnerable v = e.v();
        (uint88 col,, Vulnerable.SR status) = v.shortRecords(address(e), 3);
        assertEq(uint256(status), uint256(Vulnerable.SR.Closed), "SR#3 must stay Closed");
        assertEq(col, 20 ether, "SR#3's stale field (15 ether) was re-credited with 5 more ether it can never pay out");

        // Re-assert the harm directly: the closed SR can never be acted on again.
        vm.expectRevert(Vulnerable.InvalidShortId.selector);
        v.exitShort(3);
    }

    /// @notice Control: if the Short Record is NOT closed before the dispute resolves,
    /// the same restoration correctly lands on a live, still-claimable Short Record.
    function test_control_shortRecordStillOpen_creditIsRecoverable() public {
        Vulnerable v = new Vulnerable();
        v.openShort(address(this), 3, 20 ether, 8000 ether);
        v.proposeRedemption(address(this), address(this), 3, 5 ether, 2000 ether);

        // No exit happens this time — SR#3 stays open.
        v.disputeRedemption(address(this), 0);

        (uint88 col,, Vulnerable.SR status) = v.shortRecords(address(this), 3);
        assertEq(uint256(status), uint256(Vulnerable.SR.PartialFill), "control: SR#3 stays open");
        assertEq(col, 20 ether, "control: full collateral restored to a live SR");

        // The credit IS recoverable via a normal exit.
        v.exitShort(3);
        (,, Vulnerable.SR statusAfter) = v.shortRecords(address(this), 3);
        assertEq(uint256(statusAfter), uint256(Vulnerable.SR.Closed));
    }
}
