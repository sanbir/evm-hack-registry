// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    ElytraUnstakingVaultV1,
    ElytraUnstakingVaultV1Fixed,
    MiniToken
} from "./63541-c-01-receivefromdepositpool-does-not-track-assets-transferre.sol";

contract ReceiveFromDepositPoolNoTrackingTest is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    address internal constant USER = 0x00000000000000000000000000000000000055e2;

    uint256 internal constant AMOUNT = 10 ether;

    function test_exploit_receivedAlwaysZero_assetsLockedForever() public {
        Exploit e = new Exploit();
        e.run();

        // The buggy receiveFromDepositPool never credits anything.
        assertEq(e.buggyClaimable(), 0, "claimableAssets stays 0 despite 10e18 transferred in");
        // So the withdrawing user's claim pays out nothing.
        assertEq(e.buggyPaidToUser(), 0, "user claim pays 0");

        // Meanwhile the real 10e18 is stranded in the vault, unreachable.
        assertEq(e.lockedInVault(), AMOUNT, "10e18 locked in the unstaking vault");
        MiniToken asset = e.asset();
        ElytraUnstakingVaultV1 vault = e.vault();
        assertEq(asset.balanceOf(address(vault)), AMOUNT, "vault still holds the full 10e18");
        assertEq(asset.balanceOf(USER), 0, "user received nothing");

        // Harm magnitude recorded on the LOCKED-WHYPE marker at the SINK.
        MiniToken marker = e.marker();
        assertEq(marker.balanceOf(SINK), AMOUNT, "marker records 10e18 locked at SINK");
        assertEq(e.sinkMarkerBalance(), AMOUNT, "sink marker balance == locked magnitude");
    }

    function test_control_fixedReceive_creditsAndPaysOut() public {
        // The fixed variant (explicit amount) credits the full amount and the
        // user is paid in full — proving the harm is caused by the bug, not setup.
        Exploit e = new Exploit();
        e.run();

        assertEq(e.correctClaimable(), AMOUNT, "fixed credits the full 10e18");
        assertEq(e.correctPaidToUser(), AMOUNT, "fixed pays the user the full 10e18");

        // Fixed vault paid out; the control asset is NOT stranded there.
        ElytraUnstakingVaultV1Fixed fixedVault = e.fixedVault();
        MiniToken asset2 = e.asset2();
        assertEq(asset2.balanceOf(address(fixedVault)), 0, "fixed vault paid out, nothing stranded");
        assertEq(asset2.balanceOf(USER), AMOUNT, "user received full amount under the fix");

        // Direct contrast: buggy path locks everything, fixed path locks nothing.
        assertGt(e.lockedInVault(), 0, "buggy path locks funds");
        assertGt(e.correctPaidToUser(), e.buggyPaidToUser(), "fixed pays strictly more than buggy");
    }
}
