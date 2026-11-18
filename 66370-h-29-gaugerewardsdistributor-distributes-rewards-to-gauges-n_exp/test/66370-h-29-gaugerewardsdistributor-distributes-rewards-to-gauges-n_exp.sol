// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, ERC20, Gauge, Controller, Distributor} from
    "./66370-h-29-gaugerewardsdistributor-distributes-rewards-to-gauges-n.sol";

contract Finding66370Test is Test {
    function test_exploit_unregistered_gauge_takes_half() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.token().balanceOf(address(e)), 50 ether, "B staker");
        assertEq(e.token().balanceOf(address(e.gaugeA())), 50 ether, "A short");
        assertEq(e.dist().unregisteredPaid(), 50 ether, "unregistered");
        assertEq(e.token().balanceOf(e.VICTIM()), 0, "victim not paid the full 100");
    }

    function test_control_only_registered_gauge_is_paid() public {
        ERC20 token = new ERC20();
        Gauge a = new Gauge(token, address(0xA11CE));
        Gauge b = new Gauge(token, address(this));
        Controller c = new Controller();
        Distributor d = new Distributor(token, c, true);
        c.add(address(a));
        c.add(address(b));
        d.addGaugeRewardToken(address(a));
        token.mint(address(d), 100 ether);
        d.distributeRewards();
        assertEq(token.balanceOf(address(a)), 100 ether, "A receives all");
        assertEq(token.balanceOf(address(b)), 0, "B receives none");
        assertEq(d.unregisteredPaid(), 0, "none unregistered");
    }
}
