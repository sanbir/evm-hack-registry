// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Token, RewardAllStakersActionGenerator, TokenHopper} from
    "./53581-first-submission-can-be-triggered-multiple-times-sigmaprime.sol";

contract Finding53581Test is Test {
    address constant SINK = 0x000000000000000000000000000000000000D00d;

    function setUp() public {
        vm.warp(100);
    }

    function test_exploit_first_submission_multiple_is_paid_twice() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.hopper().presses(), 2, "two presses");
        assertEq(e.hopper().paid(), 200e18, "4 intervals paid");
        assertEq(e.token().balanceOf(SINK), 100e18, "the second catch-up");
        assertEq(e.token().balanceOf(address(e)), 100e18, "one legitimate catch-up kept");
        (uint256 amt, bool firstBranch) = e.generator().generateHopperActions();
        assertTrue(firstBranch, "still inside the cutoff");
        assertEq(amt, 100e18, "multiple is still 2");
    }

    function test_control_second_press_before_cutoff_reverts() public {
        Token token = new Token();
        RewardAllStakersActionGenerator generator = new RewardAllStakersActionGenerator(50e18);
        TokenHopper hopper = new TokenHopper(token, generator, address(this), true);
        token.mint(address(hopper), 400e18);
        hopper.pressButton();
        assertEq(hopper.paid(), 100e18, "one catch-up");
        vm.expectRevert(bytes("already submitted"));
        hopper.pressButton();
        assertEq(hopper.presses(), 1, "second press did not land");
        assertEq(token.balanceOf(address(this)), 100e18, "no extra EIGEN");
    }
}
