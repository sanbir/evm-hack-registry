// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, RewardToken, BaseGauge, GaugeController} from
    "./57160-gauge-period-cannot-be-updated-codehawks-regnum-aurum-acquis.sol";

contract Finding57160Test is Test {
    function test_exploit_expired_period_sticks_1000_rewards() public {
        Exploit e = new Exploit();
        e.run();

        assertTrue(e.notifyReverted(), "notify reverted");
        assertEq(e.stuck(), 1000 ether, "stuck");
        assertEq(e.claimed(), 0, "claim 0");
        assertEq(e.token().balanceOf(address(e.gauge())), 1000 ether, "gauge holds 1000");
        assertEq(e.token().balanceOf(e.staker()), 0, "staker got nothing");
        assertEq(e.gauge().accounted(), 0, "not accounted");
        assertEq(e.gauge().distributed(), 1000 ether, "cap still full");
    }

    function test_control_update_period_pays_staker_1000() public {
        RewardToken token = new RewardToken();
        BaseGauge gauge = new BaseGauge(token, 1000 ether);
        GaugeController controller = new GaugeController(gauge);
        gauge.setController(address(controller));
        gauge.stake(address(0xB0B), 1 ether);

        token.mint(address(this), 1000 ether);
        token.transfer(address(gauge), 1000 ether);
        controller.distributeFixed(1000 ether);
        uint256 got = gauge.claim(address(0xB0B));

        assertEq(got, 1000 ether, "paid");
        assertEq(token.balanceOf(address(0xB0B)), 1000 ether, "staker");
        assertEq(token.balanceOf(address(gauge)), 0, "gauge empty");
        assertEq(gauge.distributed(), 1000 ether, "new period used");
    }
}
