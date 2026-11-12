// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    GaugeFixed,
    Token
} from "./62814-h-7-in-the-incentivegauge-upsertincentive-function-updatepo.sol";

contract Finding62814Test is Test {
    uint256 internal constant TS = 1_700_000_000;

    function test_exploit_staker_is_paid_the_stale_window() public {
        vm.warp(TS);
        Exploit e = new Exploit();
        e.run();

        assertEq(e.paidAmount(), 86_400 ether, "paid");
        assertEq(e.fairAmount(), 0, "fair");
        assertGt(e.paidAmount(), e.fairAmount(), "overpay");
        assertEq(e.reward().balanceOf(address(e)), 86_400 ether, "staker received N");
        assertEq(e.reward().balanceOf(address(e.gauge())), e.budgetAmount() - 86_400 ether, "gauge short by N");
        assertEq(e.gauge().poolLast(), TS, "checkpoint moved only on the claim");
    }

    function test_control_checkpoint_pays_the_fair_amount() public {
        vm.warp(TS);
        Token reward = new Token();
        GaugeFixed gauge = new GaugeFixed(reward);
        uint256 budget = 7 days * 1 ether;
        uint64 stale = uint64(block.timestamp - 1 days);

        reward.mint(address(gauge), budget);
        gauge.seed(address(this), stale);
        gauge.upsertIncentive(budget);
        gauge.claim();

        assertEq(gauge.paid(), 0, "control pays fair 0");
        assertEq(reward.balanceOf(address(this)), 0, "staker receives nothing");
        assertEq(reward.balanceOf(address(gauge)), budget, "budget stays in the gauge");
        assertEq(gauge.poolLast(), TS, "pool was checkpointed before the rate");
    }
}
