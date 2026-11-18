// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Token, WheelOfGuantuneFixed} from
    "./45548-c-03-number-of-available-spins-is-never-decreased-on-spin-or.sol";

contract Finding45548Test is Test {
    function test_exploit_one_spin_drains_prize_pool() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.taken(), 50 ether, "five prizes");
        assertEq(e.spinsLeft(), 1, "allocation never decreased");
        assertEq(e.prize().balanceOf(address(e)), 50 ether, "attacker holds the pool");
        assertEq(e.prize().balanceOf(address(e.wheel())), 0, "wheel empty");
        assertEq(e.wheel().getAvailableSpinsOf(address(e)), 1, "still one spin");
    }

    function test_control_second_spin_reverts_after_decrement() public {
        Token prize = new Token();
        WheelOfGuantuneFixed wheel = new WheelOfGuantuneFixed(prize);
        prize.mint(address(wheel), 50 ether);
        wheel.giveExtraSpins(address(this), 1);

        uint256 left = wheel.spin();
        assertEq(left, 0, "allocation consumed");
        assertEq(prize.balanceOf(address(this)), 10 ether, "one prize");
        assertEq(wheel.getAvailableSpinsOf(address(this)), 0, "zero spins left");
        assertEq(prize.balanceOf(address(wheel)), 40 ether, "rest of the pool stays");

        vm.expectRevert(bytes("no spins"));
        wheel.spin();
    }
}
