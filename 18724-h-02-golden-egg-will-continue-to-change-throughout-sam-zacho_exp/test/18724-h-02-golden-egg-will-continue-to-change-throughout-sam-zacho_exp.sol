// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Exploit, SoundEdition} from "./18724-h-02-golden-egg-will-continue-to-change-throughout-sam-zacho.sol";

contract Finding18724Test is Test {
    address internal constant SELLER = 0x2222222222222222222222222222222222222222;

    function test_buyer_pays_for_egg_4_then_id_moves_to_3() public {
        Exploit e = new Exploit();
        e.run();

        SoundEdition edition = e.edition();
        assertEq(e.eggBefore(), 4, "egg was 4");
        assertEq(e.eggAfter(), 3, "egg moved to 3");
        assertEq(edition.ownerOf(4), address(e), "buyer holds 4");
        assertEq(e.eggOwner(), edition.ownerOf(3), "egg owner is token 3");
        assertTrue(e.eggOwner() != address(e), "buyer is not the egg");
        assertEq(e.sellerPaid(), 100 ether, "seller took 100");
        assertEq(e.token().balanceOf(SELLER), 100 ether, "seller balance");
        assertEq(e.token().balanceOf(address(e)), 0, "buyer spent the 100");
        assertEq(edition.editionMaxMintable(), 5, "max tracks the new mint");

        console2.log("egg before", e.eggBefore());
        console2.log("egg after", e.eggAfter());
        console2.log("seller paid", e.sellerPaid());
    }

    function test_control_freezes_egg_id_at_4() public {
        Exploit e = new Exploit();
        e.runControl();

        assertEq(e.controlEgg(), 4, "frozen egg is 4");
        assertEq(e.controlHeld(), 4, "buyer bought 4");
        assertTrue(e.controlStillEgg(), "buyer still holds the egg");

        console2.log("control egg", e.controlEgg());
        console2.log("control held", e.controlHeld());
    }
}
