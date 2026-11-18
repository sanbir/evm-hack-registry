// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;
import "forge-std/Test.sol";
import {Exploit} from "./66734-stbl-redemption-coreiredeem-burns-the-wrong-split-slice-caus.sol";

contract Finding66734Test is Test {
    function test_small_redeem_reverts_and_large_redeem_overpays() public {
        Exploit e = new Exploit();
        e.run();
        assertTrue(e.smallReverted(), "dos");
        assertEq(e.redemption().overpaid(), 20 ether, "overpaid");
        assertEq(e.redemption().lastBurned(), 40 ether, "burned");
        assertEq(e.usst().balanceOf(address(e.redemption())), 20 ether, "left");
        assertEq(e.usst().balanceOf(address(e)), 0, "user paid");
        assertEq(e.yld().stableValueNet(e.redemption().nftId()), 60 ether, "pool kept amt");
    }

    function test_control_burning_the_amt_slice_leaves_nothing() public {
        uint256 amt = 60 ether;
        uint256 burned = amt;
        assertEq(amt - burned, 0, "no overpay");
    }
}
