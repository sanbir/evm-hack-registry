// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./62092-h-01-the-poolexposure-for-token1-is-erroneously-calculated-a.sol";

contract Panoptic62092Test is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.buggyNav(), 1050e18, "buggy nav 1050");
        assertEq(e.correctNav(), 1250e18, "correct nav 1250");
        assertEq(e.attackerProfit(), 100e18, "100 profit");
    }

    function test_exposureOperands() public {
        MockERC20 u = new MockERC20("U");
        MockPanopticPool p = new MockPanopticPool();
        PanopticVaultAccountant a = new PanopticVaultAccountant(p, u);
        p.setMockPremiums(
            LeftRight.wrap((uint256(150e18) << 128) | uint256(200e18)),
            LeftRight.wrap((uint256(50e18) << 128) | uint256(50e18))
        );
        u.setBalance(address(0xBEEF), 1000e18);
        assertEq(a.computeNAV(address(0xBEEF)), 1050e18);
        assertEq(a.computeNAVCorrect(address(0xBEEF)), 1250e18);
    }
}
