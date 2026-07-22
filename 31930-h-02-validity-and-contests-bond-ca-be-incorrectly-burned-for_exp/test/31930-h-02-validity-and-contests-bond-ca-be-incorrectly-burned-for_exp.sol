// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./31930-h-02-validity-and-contests-bond-ca-be-incorrectly-burned-for.sol";

/*//////////////////////////////////////////////////////////////////////////
    Taiko [H-02] — validity bond incorrectly burned for the correct, ultimately
    verified transition.

    Driver test for the cheatcode-free synthetic. Deploys the Exploit (which
    builds the reduced TaikoL1 bond system in its constructor), runs the
    attack sequence, and independently re-asserts the harm:
      * Bob's 1000 TKO validity bond leaves his balance when he proves T1,
      * a later guardian re-prove of the SAME parent overwrites the record,
      * verifyBlock() pays the CURRENT record holder (guardian), not Bob,
      * Bob never recovers his bond even though his T1 was the correct,
        ultimately-verified transition.
//////////////////////////////////////////////////////////////////////////*/
contract ValidityBondBurnedTest is Test {
    function test_bobLosesValidityBond_forTheCorrectTransition() public {
        Exploit exp = new Exploit();
        MockTko tko = exp.tko();
        Actor bob = exp.bob();
        Actor guardian = exp.guardian();

        assertEq(tko.balanceOf(address(bob)), exp.BOB_BOND(), "bob starts funded with his bond");
        assertEq(tko.balanceOf(address(guardian)), 0, "guardian starts with nothing");

        // === attack: bob proves correct T1 -> guardian re-proves same parent -> verify ===
        exp.run();

        // HARM #1 — Bob's validity bond is gone, permanently.
        assertEq(tko.balanceOf(address(bob)), 0, "bob's bond never came back");

        // HARM #2 — the guardian (last prover of record) only receives the
        // liveness bond, because the on-record validityBond was overwritten
        // to the guardian's own (zero) bond amount.
        assertEq(tko.balanceOf(address(guardian)), exp.l1().LIVENESS_BOND(), "guardian only gets the liveness bond");

        // HARM #3 — Bob's 1000 TKO validity bond is left PERMANENTLY LOCKED
        // inside the TaikoL1 contract — frozen, unclaimable by anyone,
        // despite Bob's T1 being the correct, ultimately-verified transition.
        assertEq(tko.balanceOf(address(exp.l1())), exp.BOB_BOND(), "bob's bond is frozen inside the contract");

        // HARM #4 — the on-record transition state no longer references Bob
        // at all, even though it was his transition that got verified.
        (, , , address recordedProver, ) = exp.l1().transitions(exp.PARENT());
        assertEq(recordedProver, address(guardian), "bob's authorship of the verified transition is erased");
    }

    /// @notice Control: if nobody ever overwrites Bob's transition record
    ///         (no contest, no guardian re-prove), verifyBlock() correctly
    ///         refunds Bob's own bond to Bob — the bug requires an
    ///         intervening re-prove of the SAME parent by another address.
    function test_control_noOverride_bobIsRefundedCorrectly() public {
        MockTko tko = new MockTko();
        TaikoL1 l1 = new TaikoL1(tko);
        Actor bob = new Actor();

        uint96 bond = 1000 ether;
        tko.mint(address(bob), bond);
        tko.mint(address(l1), l1.LIVENESS_BOND()); // liveness bond pre-escrowed at proposal time
        bytes32 parent = keccak256("solo-parent");

        bob.proveBlock(l1, parent, 100, bond);
        assertEq(tko.balanceOf(address(bob)), 0, "bond posted");

        l1.verifyBlock(parent);
        assertEq(tko.balanceOf(address(bob)), uint256(bond) + l1.LIVENESS_BOND(), "bob correctly refunded when never overwritten");
    }
}
