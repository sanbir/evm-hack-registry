// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./30897-h-2-setting-the-strategy-cap-to-0-does-not-update-the-total.sol";

contract StrategyCapZeroDoubleCountTest is Test {
    Exploit internal exploit;

    function setUp() public {
        exploit = new Exploit();
    }

    function test_exploit() public {
        exploit.run();

        AssetRegistry ar = exploit.assetRegistry();
        MockDelegationManager dm = exploit.delegationManager();
        Coordinator coord = exploit.coordinator();

        // Re-assert the harm from outside run(): the shares held ledger never
        // dropped, yet both the admin's EigenLayer exit AND the user's
        // withdrawal request claim the SAME 500e18 shares.
        assertEq(ar.getAssetSharesHeld(), 500e18, "sharesHeld should still read the stale, inflated value");
        assertEq(dm.totalQueuedForWithdrawal(), 500e18, "admin's forced exit should be queued in EigenLayer");
        assertEq(coord.sharesAlreadyQueuedThisEpoch(), 500e18, "user withdrawal should have been accepted");

        uint256 totalCommitted = dm.totalQueuedForWithdrawal() + coord.sharesAlreadyQueuedThisEpoch();
        assertEq(totalCommitted, 1000e18, "total commitments should double count the 500e18 shares");
        assertGt(totalCommitted, ar.getAssetSharesHeld(), "commitments must exceed the real backing shares");
    }

    /// @notice Control: if the admin instead LOWERS the cap without zeroing it
    ///         (no forced full exit), no EigenLayer exit is queued and a
    ///         user's withdrawal request is checked against an unchanged,
    ///         correctly-backed share balance — no double counting occurs.
    function test_control_nonZeroCapChangeDoesNotDoubleCount() public {
        MockDelegationManager dm = new MockDelegationManager();
        AssetRegistry ar = new AssetRegistry();
        OperatorDelegator delegator = new OperatorDelegator(address(dm));
        OperatorRegistry registry = new OperatorRegistry(address(ar));
        Coordinator coord = new Coordinator(address(ar));

        ar.increaseSharesHeldForAsset(500e18);
        registry.registerOperator(1, address(delegator), 1e18, 500e18);

        // Admin lowers the cap but keeps it non-zero -> no forced exit branch.
        registry.setOperatorStrategyCap(1, 0.5e18);
        assertEq(dm.totalQueuedForWithdrawal(), 0, "no exit should be queued for a non-zero cap change");

        // A user can withdraw once, up to the real backing amount, and a
        // second withdrawal for the same shares correctly reverts (no
        // phantom capacity was created).
        coord.requestWithdrawal(500e18);
        vm.expectRevert(bytes("INSUFFICIENT_SHARES_FOR_WITHDRAWAL"));
        coord.requestWithdrawal(1); // even 1 more wei of shares correctly has no capacity left
    }
}
