// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Token, BaseGaugeFixed} from "./66158-c-04-failure-to-update-user-integral-enables-double-reward-a.sol";

contract Finding66158Test is Test {
    function test_exploit_updateUserRewards_pays_the_same_rewards_twice() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.received(), 2000 ether, "double");
        assertEq(e.token().balanceOf(address(e)), 2000 ether, "attacker");
        assertEq(e.token().balanceOf(address(e.gauge())), 0, "gauge empty");
    }

    function test_control_integral_update_pays_once() public {
        Token token = new Token();
        BaseGaugeFixed gauge = new BaseGaugeFixed(token);
        gauge.stake(address(this), 1000 ether);
        gauge.seed(address(this), 1e18);
        token.mint(address(gauge), 2000 ether);
        gauge.updateUserRewards();
        gauge.claimRewards();
        assertEq(token.balanceOf(address(this)), 1000 ether, "fair");
        assertEq(token.balanceOf(address(gauge)), 1000 ether, "rest");
    }
}
