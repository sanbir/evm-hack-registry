// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, StakingManager, EthToken} from
    "./58595-initialization-upon-declaration-will-not-work-for-proxied-co.sol";

contract Finding58595Test is Test {
    function test_exploit_proxy_skips_fee() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.implementation().unstakeFeeRate(), 10, "impl rate 10");
        assertEq(e.ethToken().balanceOf(address(this)), 1_000e18, "user paid 1000");
        assertEq(e.ethToken().balanceOf(address(0xF1)), 900e18, "control user 900");
        assertEq(e.ethToken().balanceOf(address(e.proxy())), 0, "proxy emptied");
        assertEq(e.ethToken().balanceOf(address(e.controlProxy())), 100e18, "control keeps 100");
    }

    function test_control_initialized_proxy_keeps_fee() public {
        EthToken token = new EthToken();
        StakingManager impl = new StakingManager(token);
        assertEq(impl.unstakeFeeRate(), 10, "declaration sets 10");
    }
}
