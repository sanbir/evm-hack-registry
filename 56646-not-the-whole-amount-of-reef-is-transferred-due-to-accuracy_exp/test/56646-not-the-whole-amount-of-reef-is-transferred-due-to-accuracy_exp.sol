// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, RaffleFixed} from "./56646-not-the-whole-amount-of-reef-is-transferred-due-to-accuracy.sol";

contract Finding56646Test is Test {
    address internal constant SELLER = 0x3333333333333333333333333333333333333333;

    function test_exploit_fractional_reef_stuck() public {
        Exploit e = new Exploit();
        e.run{value: 2.5 ether}();

        assertEq(e.entered(), 2.5 ether, "entered 2.5");
        assertEq(e.wholeReef(), 2, "recorded 2");
        assertEq(e.payout(), 2 ether, "paid 2");
        assertEq(e.stuck(), 0.5 ether, "stuck 0.5");
        assertEq(address(e).balance, 0.5 ether, "contract holds 0.5");
        assertEq(SELLER.balance, 2 ether, "seller received 2");
    }

    function test_control_pays_full_value() public {
        RaffleFixed fixedRaffle = new RaffleFixed(SELLER);
        uint256 before = SELLER.balance;
        fixedRaffle.run{value: 2.5 ether}();

        assertEq(fixedRaffle.payout(), 2.5 ether, "control pays 2.5");
        assertEq(fixedRaffle.stuck(), 0, "control sticks nothing");
        assertEq(address(fixedRaffle).balance, 0, "control empty");
        assertEq(SELLER.balance - before, 2.5 ether, "seller received 2.5");
    }
}
