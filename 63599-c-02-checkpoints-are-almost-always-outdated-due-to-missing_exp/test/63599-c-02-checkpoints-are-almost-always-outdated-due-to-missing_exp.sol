// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    StrategyWrapper,
    StrategyWrapperFixed,
    MiniToken,
    Actor
} from "./63599-c-02-checkpoints-are-almost-always-outdated-due-to-missing.sol";

// StakeDAO C-02: the strategy wrapper never overrides ERC20 `_update`, so a
// plain transfer (e.g. a Morpho Blue collateral seizure during liquidation)
// moves the wrapper token WITHOUT creating a checkpoint for the recipient.
// The recipient's redeem then runs `checkpoint.balance -= amount` against a
// zero checkpoint, underflows, and reverts forever — the tokens are locked.
contract CheckpointUnderflowLockTest is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    uint256 internal constant AMOUNT = 1_000 ether;

    function test_exploit_missingUpdateOverride_locksTransferredTokens() public {
        Exploit e = new Exploit();
        e.run();

        // Harm: Bob's redeem reverted on the checkpoint underflow.
        assertTrue(e.bobRedeemReverted(), "Bob's redeem must revert (checkpoint underflow)");

        // Harm magnitude: Bob still holds the full 1000e18 wrapper tokens, and
        // they are unredeemable -> permanently locked.
        assertEq(e.lockedBalance(), AMOUNT, "Bob retains the locked wrapper tokens");

        StrategyWrapper wrapper = StrategyWrapper(e.wrapperAddr());
        assertEq(wrapper.balanceOf(e.bobAddr()), AMOUNT, "Bob's balance is real ERC20 balance");

        // The underlying that backs Bob's tokens is stranded inside the wrapper:
        // Bob can never pull it out.
        MiniToken underlying = wrapper.underlying();
        assertEq(underlying.balanceOf(e.wrapperAddr()), AMOUNT, "underlying stranded in wrapper");
        assertEq(underlying.balanceOf(e.bobAddr()), 0, "Bob got 0 underlying back");

        // Marker records the locked magnitude at the SINK.
        MiniToken marker = MiniToken(e.markerAddr());
        assertEq(marker.balanceOf(SINK), AMOUNT, "marker records locked amount at SINK");
        assertEq(e.sinkMarkerBalance(), AMOUNT, "sink marker balance matches locked amount");
    }

    // Negative control: with `_update` overridden (the auditor's fix), the exact
    // same transfer carries the checkpoint to Bob, and his redeem SUCCEEDS.
    function test_control_updateOverride_transfersCheckpoint_redeemSucceeds() public {
        MiniToken underlying = new MiniToken("Curve LP", "crvLP");
        StrategyWrapperFixed wrapper = new StrategyWrapperFixed(address(underlying));

        Actor alice = new Actor();
        Actor bob = new Actor();

        underlying.mint(address(alice), AMOUNT);
        alice.approve(address(underlying), address(wrapper), AMOUNT);
        alice.deposit(address(wrapper), AMOUNT);

        // Same transfer that broke the vulnerable wrapper.
        alice.transferWrapped(address(wrapper), address(bob), AMOUNT);

        // Checkpoint followed the transfer: Bob now has a checkpoint of AMOUNT.
        (uint256 bobCp,) = wrapper.userCheckpoints(address(bob));
        assertEq(bobCp, AMOUNT, "fix: checkpoint transferred to Bob");
        (uint256 aliceCp,) = wrapper.userCheckpoints(address(alice));
        assertEq(aliceCp, 0, "fix: Alice checkpoint drained by transfer");

        // Bob's redeem succeeds and he receives the underlying back.
        bool ok = bob.tryRedeem(address(wrapper), AMOUNT);
        assertTrue(ok, "fix: Bob redeem succeeds");
        assertEq(underlying.balanceOf(address(bob)), AMOUNT, "fix: Bob got underlying back");
        assertEq(wrapper.balanceOf(address(bob)), 0, "fix: Bob's wrapper tokens burned on redeem");
    }
}
