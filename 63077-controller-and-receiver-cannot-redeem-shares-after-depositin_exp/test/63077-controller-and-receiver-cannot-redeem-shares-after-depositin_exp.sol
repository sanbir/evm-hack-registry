// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    SuperVault,
    SuperVaultFixed,
    SuperVaultStrategy,
    ISuperVaultStrategy,
    MiniToken
} from "./63077-controller-and-receiver-cannot-redeem-shares-after-depositin.sol";

contract SuperformControllerReceiverRedeemLockTest is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    address internal constant ALICE = address(0xA11CE); // controller / depositor
    address internal constant BOB = address(0xB0B); // receiver / share holder

    uint256 internal constant DEPOSIT = 100_000_000; // 100 USDC (6 decimals)

    // ── Exploit: receiver != controller => the deposit is permanently locked ──
    function test_exploit_receiverDiffersFromController_lockedForever() public {
        Exploit e = new Exploit();
        e.run();

        // The share/state split: receiver holds shares, controller holds state.
        assertEq(e.receiverShares(), DEPOSIT, "receiver holds the shares");
        assertEq(e.receiverStateShares(), 0, "receiver has EMPTY strategy state");
        assertEq(e.controllerStateShares(), DEPOSIT, "controller wrongly holds the state");

        // Neither party can redeem.
        assertTrue(e.receiverRedeemReverted(), "receiver redeem must revert (INSUFFICIENT_SHARES)");
        assertTrue(e.controllerRedeemReverted(), "controller redeem must revert (no shares)");

        // The 100 USDC deposit is stranded in the vault, unredeemable.
        assertEq(e.lockedAssets(), DEPOSIT, "100 USDC locked in the vault");

        // Locked magnitude recorded on the LOCKED-USDC marker at the SINK.
        MiniToken marker = MiniToken(e.markerAddr());
        assertEq(marker.balanceOf(SINK), DEPOSIT, "marker records the locked amount at SINK");
    }

    // Directly exercise the verbatim `_calculateCostBasis` INSUFFICIENT_SHARES
    // revert against the real buggy vault, from the receiver (share-holder) side.
    function test_exploit_receiverRedeem_revertsInsufficientShares() public {
        MiniToken usdc = new MiniToken("USD Coin", "USDC", 6);
        SuperVaultStrategy strategy = new SuperVaultStrategy();
        SuperVault vault = new SuperVault(usdc, strategy);
        strategy.initialize(address(vault));

        usdc.mint(ALICE, DEPOSIT);
        vm.startPrank(ALICE);
        usdc.approve(address(vault), DEPOSIT);
        vault.deposit(DEPOSIT, BOB); // controller = ALICE, receiver = BOB
        vm.stopPrank();

        assertEq(vault.balanceOf(BOB), DEPOSIT, "BOB got the shares");
        (uint256 bobShares,) = strategy.getState(BOB);
        assertEq(bobShares, 0, "BOB has no cost-basis state");

        // BOB owns the shares but the fulfilment reads BOB's empty state -> revert.
        vm.prank(BOB);
        vm.expectRevert(SuperVaultStrategy.INSUFFICIENT_SHARES.selector);
        vault.redeem(DEPOSIT, BOB, BOB);

        // ALICE owns the state but no shares -> cannot even request.
        vm.prank(ALICE);
        vm.expectRevert(SuperVault.NoSharesToRedeem.selector);
        vault.redeem(DEPOSIT, ALICE, ALICE);

        // Funds remain locked.
        assertEq(usdc.balanceOf(address(vault)), DEPOSIT, "USDC locked in vault");
    }

    // ── Negative control: the fixed vault credits state to the receiver, so the
    //    receiver redeems successfully and recovers the assets. ────────────────
    function test_control_fixed_receiverRedeemsSuccessfully() public {
        MiniToken usdc = new MiniToken("USD Coin", "USDC", 6);
        SuperVaultStrategy strategy = new SuperVaultStrategy();
        SuperVaultFixed vault = new SuperVaultFixed(usdc, strategy);
        strategy.initialize(address(vault));

        usdc.mint(ALICE, DEPOSIT);
        vm.startPrank(ALICE);
        usdc.approve(address(vault), DEPOSIT);
        vault.deposit(DEPOSIT, BOB); // controller = ALICE, receiver = BOB
        vm.stopPrank();

        // FIX: state credited to the receiver (BOB), who also holds the shares.
        assertEq(vault.balanceOf(BOB), DEPOSIT, "BOB got the shares");
        (uint256 bobShares,) = strategy.getState(BOB);
        assertEq(bobShares, DEPOSIT, "BOB holds the matching cost-basis state");

        // BOB redeems successfully and recovers the full 100 USDC.
        vm.prank(BOB);
        uint256 assets = vault.redeem(DEPOSIT, BOB, BOB);
        assertEq(assets, DEPOSIT, "redeem returns the deposited assets");
        assertEq(usdc.balanceOf(BOB), DEPOSIT, "BOB recovered the assets");
        assertEq(usdc.balanceOf(address(vault)), 0, "vault fully drained back to the user");
    }
}
