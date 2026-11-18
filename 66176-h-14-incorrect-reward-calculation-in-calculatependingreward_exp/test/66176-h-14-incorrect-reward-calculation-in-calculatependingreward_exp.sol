// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit} from "./66176-h-14-incorrect-reward-calculation-in-calculatependingreward.sol";

contract Finding66176Test is Test {

    function test_exploit_pays_distributor_rate() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.fair(), 100 ether, "fair");
        assertEq(e.claimed(), 200 ether, "claimed");
        assertEq(e.token().balanceOf(address(this)), 200 ether, "attacker");
        assertEq(e.token().balanceOf(address(e.gauge())), 0, "pot");
        assertEq(e.gauge().currentRate(), 200 ether, "rate overwritten");
    }

    function test_control_notified_rate_leaves_half() public {
        Exploit e = new Exploit();
        e.gauge().stake(address(this), 1 ether);
        uint256 got = e.gauge().claimFixed(address(this));
        assertEq(got, 100 ether, "notified");
        assertEq(e.token().balanceOf(address(e.gauge())), 100 ether, "other gauge share remains");
    }

}
