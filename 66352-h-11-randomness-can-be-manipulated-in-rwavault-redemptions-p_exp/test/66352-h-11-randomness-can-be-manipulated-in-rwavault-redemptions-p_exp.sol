// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;
import "forge-std/Test.sol";
import {Exploit} from "./66352-h-11-randomness-can-be-manipulated-in-rwavault-redemptions-p.sol";

contract Finding66352Test is Test {
    function test_bob_rolls_until_he_receives_alices_nft() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.FINDING(), 66352, "id");
        assertEq(e.firstId(), 1, "rejected");
        assertGe(e.spins(), 1, "retried");
        assertEq(e.rwa().ownerOf(2), address(e), "bob owns 2");
        assertEq(e.rwa().ownerOf(1), address(e.vault()), "1 back in vault");
    }
}
