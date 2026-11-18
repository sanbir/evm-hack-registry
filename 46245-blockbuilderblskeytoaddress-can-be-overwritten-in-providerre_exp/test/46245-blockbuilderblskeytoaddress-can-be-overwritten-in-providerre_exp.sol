// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;
import "forge-std/Test.sol";
import {Exploit} from "./46245-blockbuilderblskeytoaddress-can-be-overwritten-in-providerre.sol";

contract Finding46245Test is Test {
    function test_overwrite_pays_bid_to_the_second_registrant() public {
        Exploit e = new Exploit();
        vm.deal(address(this), 1 ether);
        e.run{value: 0.2 ether}();
        assertTrue(e.honestBlocked(), "honest blocked");
        assertEq(e.token().balanceOf(address(e)), 10 ether, "attacker paid");
        assertEq(e.token().balanceOf(address(e.honest())), 0, "honest unpaid");
        assertEq(e.tracker().winnerOf(1), address(e), "winner");
    }
}
