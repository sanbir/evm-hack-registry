// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./27476-users-can-loose-collateral-when-exiting-a-short-codehawks-di.sol";

contract DittoExitShortSelfMatchTest is Test {
    function test_UserLoosesCollateralOnMatchingWithOwnShort() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.correctCollateralWouldHaveBeen(), 300);
        assertEq(e.ethEscrowedAfterExit(), 150);
        assertEq(e.withdrawnAfterExit(), 150);
    }

    /// @dev Control: if the exit bid is fully filled WITHOUT matching the
    ///      user's own resting order (i.e. no self-match happens), the
    ///      snapshot correctly equals the current state and exitShort
    ///      disburses the right amount — proving the loss is specifically
    ///      caused by the self-match mutating the SAME ShortRecord mid-call.
    function test_Control_NoSelfMatch_CorrectDisbursement() public {
        MockToken token = new MockToken();
        ShortExitManager sm = new ShortExitManager(token);
        Actor sender = new Actor(token, sm);

        sender.deposit(500);
        // fully filled at creation (no resting order at all -> nothing to self-match)
        (uint256 shortId,) = sender.createLimitShort(50, 50, 1);
        (, uint256 debt, uint256 collateral,) = sm.shortRecords(shortId);
        assertEq(debt, 50);
        assertEq(collateral, 150);

        // exitShort with hintOrderId = 0 (no resting order exists to match)
        // is not applicable here since our reduction requires a hint order;
        // instead simulate a THIRD PARTY's resting order being matched
        // (not the same ShortRecord) to show the branch is only wrong when
        // the SAME ShortRecord is matched into.
        Actor other = new Actor(token, sm);
        other.deposit(500);
        (uint256 otherShortId, uint256 otherRestingId) = other.createLimitShort(50, 0, 1);
        assertTrue(otherShortId != shortId);

        uint256 senderEscrowedBefore = sm.ethEscrowed(address(sender)); // free margin after locking 250 for the short
        sender.exitShort(shortId, 50, 1, otherRestingId);
        // sender's OWN shortRecord's snapshot (50) matches the fill (50),
        // and since the match hit `other`'s order (not sender's own), no
        // extra collateral was ever added to sender's ShortRecord — the
        // disbursed snapshot (150) IS the correct, up-to-date value, so
        // exactly 150 (not less) is credited back.
        assertEq(sm.ethEscrowed(address(sender)) - senderEscrowedBefore, 150);
    }
}
