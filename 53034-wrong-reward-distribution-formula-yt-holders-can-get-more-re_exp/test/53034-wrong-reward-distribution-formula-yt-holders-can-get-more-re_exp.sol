// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, RewardToken} from "./53034-wrong-reward-distribution-formula-yt-holders-can-get-more-re.sol";

contract Finding53034Test is Test {
    function test_exploit_alice_receives_56_25_and_bob_43_75() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.alicePaid(), 56.25 ether, "alice paid");
        assertEq(e.bobPaid(), 43.75 ether, "bob paid");
        assertEq(e.reward().balanceOf(address(e)), 56.25 ether, "alice balance");
        assertEq(e.reward().balanceOf(e.bob()), 43.75 ether, "bob balance");
        assertGt(e.alicePaid(), e.bobPaid(), "alice ahead");
    }

    function test_control_no_early_claim_pays_50_each() public {
        Exploit e = new Exploit();
        (uint256 alice, uint256 bobPaid) = e.runFair();

        assertEq(alice, 50 ether, "alice fair");
        assertEq(bobPaid, 50 ether, "bob fair");
        assertEq(e.reward().balanceOf(address(e)), 50 ether, "alice 50");
        assertEq(e.reward().balanceOf(e.bob()), 50 ether, "bob 50");
    }
}
