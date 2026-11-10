// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Exploit, MockTAP, VestingFixed} from "./32316-h-05-vested-claimable-amount-calculation-error-code4rena-ta.sol";

contract Finding32316Test is Test {
    uint256 internal constant NOW = 1999;
    uint256 internal constant CLAIMED = 549;
    uint256 internal constant FAIR = 500;

    function setUp() public {
        vm.warp(NOW);
    }

    function test_exploit_claimed_549_fair_500() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.claimed(), CLAIMED, "claimed 549");
        assertEq(e.fair(), FAIR, "fair 500");
        assertEq(e.claimed() - e.fair(), 49, "overpay 49");
        assertEq(e.tap().balanceOf(address(e)), CLAIMED, "user paid 549");
        assertEq(block.timestamp, NOW, "report timestamp");
    }

    function test_control_corrected_formula_pays_500() public {
        MockTAP tap = new MockTAP();
        VestingFixed vesting = new VestingFixed(address(tap));
        tap.mint(address(vesting), 549);

        uint256 paid = vesting.claim();

        assertEq(paid, FAIR, "control pays the fair 500");
        assertEq(tap.balanceOf(address(this)), FAIR, "user receives 500");
        assertEq(tap.balanceOf(address(vesting)), 49, "the 49 excess stays unclaimed");
        assertEq(vesting.fairAmount(), FAIR, "view agrees");
    }
}
