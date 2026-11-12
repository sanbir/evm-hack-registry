// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Bgt,
    Exploit,
    IWrongBoost,
    Reward,
    Staker
} from "./55115-h-05-incorrect-activateboost-interface-is-used-pashov-audit.sol";

contract Finding55115Test is Test {
    function test_exploit_wrong_boost_interface_leaves_7() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.stuck(), 7 ether, "7 stuck");
        assertEq(e.paid(), 0, "user received nothing");
        assertFalse(e.boosted(), "boost reverted");
    }

    function test_control_two_arg_activateBoost_pays_7() public {
        Reward token = new Reward();
        Bgt bgt = new Bgt(token);
        Staker staker = new Staker(IWrongBoost(address(bgt)), address(0xBEEF));
        token.mint(address(bgt), 7 ether);
        staker.setBoost(7 ether, 8192);
        staker.pokeFixed(address(this));
        assertEq(token.balanceOf(address(this)), 7 ether, "user received 7");
        assertEq(token.balanceOf(address(bgt)), 0, "vault empty");
    }
}
