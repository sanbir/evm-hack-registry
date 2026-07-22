// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./32318-h-07-incorrect-math-means-dataremoveandrepaydataremoveassetf.sol";

/*//////////////////////////////////////////////////////////////////////////
    Tapioca DAO [H-07] — removeAssetFromSGL will never work once SGL has
    accrued interest.

    Driver test for the cheatcode-free synthetic. Deploys the Exploit (which
    builds the reduced YieldBox/Singularity/Magnetar system and deposits +
    accrues interest in its constructor), runs the attack sequence, and
    independently re-asserts the harm:
      * a well-covered, ordinary withdrawal via Magnetar's removeAssetFromSGL
        REVERTS once any interest has accrued, even though the user's SGL
        balance comfortably covers it,
      * the pool itself is solvent -- a correctly-scaled DIRECT call to
        Singularity succeeds and returns exactly the requested amount.
//////////////////////////////////////////////////////////////////////////*/
contract RemoveAssetFromSGLBrickedTest is Test {
    function test_removeAssetFromSGL_revertsOnceInterestHasAccrued() public {
        Exploit exp = new Exploit();
        Singularity sgl = exp.sgl();
        MagnetarOptionModule magnetar = exp.magnetar();
        MockYieldBox yb = exp.yieldBox();
        uint256 assetId = exp.ASSET_ID();

        uint256 fractionBefore = sgl.balanceOf(address(exp));
        assertEq(fractionBefore, exp.DEPOSIT(), "attacker starts fully funded");

        // === attack: ordinary withdrawal via Magnetar reverts post-interest,
        // then a correctly-scaled direct call proves the pool itself is fine ===
        exp.run();

        // HARM #1 — the reverted Magnetar call left no trace: the attacker's
        // fraction balance decreased by EXACTLY the CONTROL path's
        // correctly-scaled amount (computed from the pre-run ratios), never
        // by anything from the buggy, reverted call.
        uint256 preRunAllShare = exp.DEPOSIT() + exp.INTEREST_ACCRUAL(); // elastic + toShare(borrowElastic), both 1:1 pre-run
        uint256 expectedCorrectFraction = (exp.REMOVE_AMOUNT() * exp.DEPOSIT()) / preRunAllShare;
        assertEq(
            sgl.balanceOf(address(exp)),
            fractionBefore - expectedCorrectFraction,
            "only the correctly-scaled CONTROL amount was ever spent -- the buggy Magnetar call reverted with zero effect"
        );

        // HARM #2 — the SAME bricked pool still rejects a proportionally
        // modest withdrawal request (half of the attacker's now-remaining
        // stake) via Magnetar: this is not a one-off, it is systemic once
        // any interest has accrued.
        uint256 halfOfRemaining = sgl.balanceOf(address(exp)) / 2;
        vm.expectRevert();
        magnetar.removeAssetFromSGL(sgl, yb, assetId, address(exp), address(exp), halfOfRemaining);
    }

    /// @notice Control: before ANY interest has accrued (totalAsset.elastic
    ///         == totalAsset.base), Magnetar's buggy math coincidentally
    ///         agrees with the correct math and the withdrawal succeeds --
    ///         confirming the bug is specifically interest-accrual-triggered.
    function test_control_noInterestAccrued_magnetarPathWorks() public {
        MockYieldBox yb = new MockYieldBox();
        Singularity sgl = new Singularity(yb, 1);
        MagnetarOptionModule magnetar = new MagnetarOptionModule();

        yb.mintTo(1, address(this), 1000 ether);
        sgl.addAsset(address(this), address(this), 1000 ether);
        // No accrueInterest() call here -- totalAsset.elastic == totalAsset.base.

        uint256 shareOut = magnetar.removeAssetFromSGL(sgl, yb, 1, address(this), address(this), 200 ether);
        assertEq(shareOut, 200 ether, "with zero accrued interest, the buggy math happens to be correct");
    }
}
