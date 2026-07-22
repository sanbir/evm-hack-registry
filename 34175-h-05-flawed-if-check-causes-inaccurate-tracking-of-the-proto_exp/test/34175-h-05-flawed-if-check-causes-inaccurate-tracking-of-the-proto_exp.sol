// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./34175-h-05-flawed-if-check-causes-inaccurate-tracking-of-the-proto.sol";

contract DittoFlawedClaimCheckTest is Test {
    function test_flawedCheckCorruptsProtocolAccounting() public {
        Exploit e = new Exploit();
        e.run();

        Vulnerable v = e.v();
        uint8[] memory ids = new uint8[](3);
        ids[0] = 1;
        ids[1] = 2;
        ids[2] = 3;
        (uint256 totalCol, uint256 totalDebt) = v.sumActiveShortRecords(address(e), ids);

        assertTrue(v.assetCollateral() != totalCol, "collateral invariant must be broken");
        assertTrue(v.assetErcDebt() != totalDebt, "ercDebt invariant must be broken");

        // The specific numbers: SR#2's collateral field is double-counted (10 + 10)
        // and its debt field is resurrected to 5000, but it stays Closed so it is
        // excluded from the active sum -> asset totals overshoot by exactly that.
        assertEq(v.assetCollateral(), totalCol + 10 ether, "collateral overshoots by SR#2's resurrected 10 ether");
        assertEq(v.assetErcDebt(), totalDebt + 5000 ether, "ercDebt overshoots by SR#2's resurrected 5000 ether");
    }

    /// @notice Control: if the shorter passes the CORRECT id matching the named
    /// redeemer's own proposal, the claim behaves as intended and no later dispute
    /// can corrupt an already-Closed Short Record's accounting.
    function test_control_correctIdMatchesProposal_noCorruption() public {
        Vulnerable v = new Vulnerable();
        v.openShort(address(this), 1, 10 ether, 5000 ether);
        v.openShort(address(this), 2, 10 ether, 5000 ether);

        v.proposeRedemption(address(this), 1, 1); // redeemer == this test contract itself for SR#1
        // (using the test contract as its own redeemer here is fine — the control
        // only needs to show the CORRECT-id path is safe)
        v.advanceTime(2);

        v.claimRemainingCollateral(address(this), 0, 1); // id matches claimProposal.shortId
        (,, Vulnerable.SR status1) = v.shortRecords(address(this), 1);
        assertEq(uint256(status1), uint256(Vulnerable.SR.Closed));

        // SR#2 was never touched — no corruption possible.
        (uint88 col2, uint88 debt2,) = v.shortRecords(address(this), 2);
        assertEq(col2, 10 ether);
        assertEq(debt2, 5000 ether);
    }
}
