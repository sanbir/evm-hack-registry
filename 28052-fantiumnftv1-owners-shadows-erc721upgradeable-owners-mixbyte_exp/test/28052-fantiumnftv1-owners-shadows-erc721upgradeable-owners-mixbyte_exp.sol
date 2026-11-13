// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Exploit} from "./28052-fantiumnftv1-owners-shadows-erc721upgradeable-owners-mixbyte.sol";

contract Finding28052Test is Test {
    function test_shadow_locks_real_owner_of_token_1000000() public {
        Exploit e = new Exploit();
        e.run();

        console2.log("token id", e.TOKEN_ID());
        console2.log("real owner is alice", e.realOwner() == address(e.alice()));
        console2.log("exists", e.existsFlag());
        console2.log("owner moved", e.ownerMoved());
        console2.log("owner claimed", e.ownerClaimed());
        console2.log("stuck", e.stuck());

        assertEq(e.TOKEN_ID(), 1_000_000, "id");
        assertEq(e.realOwner(), address(e.alice()), "owner");
        assertFalse(e.existsFlag(), "shadow exists");
        assertFalse(e.ownerMoved(), "locked out of transfer");
        assertEq(e.nft().ownerOf(1_000_000), address(e.alice()), "nft stays");
        assertFalse(e.ownerClaimed(), "locked out of claim");
        assertEq(e.stuck(), 1_000_000 ether, "proceeds stuck");
        assertEq(e.token().balanceOf(address(e.nft())), 1_000_000 ether, "balance");
        assertEq(e.token().balanceOf(address(e.alice())), 0, "alice unpaid");
    }

    function test_control_one_owner_lets_alice_move_and_claim() public {
        Exploit e = new Exploit();
        e.runControl();

        console2.log("control exists", e.controlExists());
        console2.log("control claimed", e.controlClaimed());
        console2.log("control moved", e.controlMoved());
        console2.log("attacker moved", e.controlAttackerMoved());
        console2.log("control owner is bob", e.controlOwner() == e.BOB());
        console2.log("alice received", e.controlAliceBalance());

        assertTrue(e.controlExists(), "one mapping");
        assertTrue(e.controlClaimed(), "claim");
        assertTrue(e.controlMoved(), "alice moved token 1000000");
        assertFalse(e.controlAttackerMoved(), "non-owner blocked");
        assertEq(e.controlOwner(), e.BOB(), "bob");
        assertEq(e.controlAliceBalance(), 1_000_000 ether, "paid");
    }
}
