// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {
    Exploit,
    MiniToken
} from "./18536-h-4-when-rolling-over-user-will-lose-his-winnings-from-previ.sol";

contract Finding18536Test is Test {
    function test_exploit_user_loses_previous_epoch_winnings() public {
        Exploit e = new Exploit();
        e.run();

        MiniToken asset = MiniToken(e.assetAddr());

        // Winning epoch entitled the depositor to principal + 500 ether winnings.
        assertEq(e.entitledBefore(), e.CLAIM(), "entitled to 1500");
        assertEq(e.CLAIM() - e.DEPOSIT(), e.WINNINGS(), "winnings are 500 ether");

        // Rollover reminted only the original deposit minus the relayer fee.
        assertEq(e.userReceived(), e.DEPOSIT() - e.FEE(), "received principal minus fee");
        assertEq(asset.balanceOf(e.userAddr()), e.DEPOSIT() - e.FEE(), "user balance is principal minus fee");

        // Previous-epoch shares were burned, so the winnings cannot be withdrawn.
        assertEq(e.oldEpochPayout(), 0, "old epoch pays nothing");

        // The 500 ether of previous-epoch winnings is stuck in the vault.
        assertEq(e.lostWinnings(), e.WINNINGS(), "recorded loss");
        assertEq(asset.balanceOf(e.vaultAddr()), e.WINNINGS(), "500 ether stuck in vault");
        console2.log("exploit user received wei", e.userReceived());
        console2.log("exploit winnings stuck wei", asset.balanceOf(e.vaultAddr()));
    }

    function test_control_preserves_previous_epoch_winnings() public {
        Exploit e = new Exploit();
        e.control();

        // Same fee, but the fixed rollover remints entitledShares, so the
        // depositor keeps the 500 ether winnings and the vault is empty.
        assertEq(e.controlVaultLeft(), 0, "vault keeps nothing");
        assertEq(e.controlUserReceived(), e.CLAIM() - e.FEE(), "user receives entitled minus fee");
        assertEq(e.controlUserReceived() - (e.DEPOSIT() - e.FEE()), e.WINNINGS(), "500 ether winnings preserved");
        console2.log("control user received wei", e.controlUserReceived());
        console2.log("control winnings preserved wei", e.controlUserReceived() - (e.DEPOSIT() - e.FEE()));
        console2.log("control vault left wei", e.controlVaultLeft());
    }
}
