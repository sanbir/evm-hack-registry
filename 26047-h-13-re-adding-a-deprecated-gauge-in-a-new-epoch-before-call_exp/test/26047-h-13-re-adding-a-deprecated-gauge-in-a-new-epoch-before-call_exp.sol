// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./26047-h-13-re-adding-a-deprecated-gauge-in-a-new-epoch-before-call.sol";

/*//////////////////////////////////////////////////////////////
    Maia DAO — [H-13] Re-adding a deprecated gauge in a new epoch before
    queueRewardsForCycle() leaves gauges without rewards. Finding 26047
    (Code4rena 2023-05, reporter Voyvoda) — HIGH

    _addGauge re-adds a deprecated gauge's preserved weight to _totalWeight and, in
    doing so, sets _totalWeight.currentCycle to the current cycle. When
    queueRewardsForCycle then reads _getStoredWeight(_totalWeight, currentCycle) it
    returns the STALE storedWeight (too low), while each gauge's own weight still
    reads full. The per-gauge allocations sum to more than the reward pool, so the
    last gauge to claim (here the 75% whale) reverts — its rewards are frozen.
//////////////////////////////////////////////////////////////*/
contract MaiaGaugeReAddDoSTest is Test {
    Exploit exp;

    function setUp() public {
        exp = new Exploit();
    }

    function test_readdedGauge_bricks_whale_rewards() public {
        exp.run();

        uint256 smallAlloc = exp.smallAllocCycle3();
        uint256 whaleAlloc = exp.whaleQueuedCycle3();
        uint256 pool = exp.poolAtCycle3();

        emit log_named_uint("cycle-3 small-gauge allocation", smallAlloc);
        emit log_named_uint("cycle-3 whale-gauge allocation", whaleAlloc);
        emit log_named_uint("reward pool left after small gauge", pool);
        emit log_named_uint("small gauge actually collected", exp.g1CollectedCycle3());

        // The allocations over-commit the fixed 100e18 reward pool.
        assertGt(smallAlloc + whaleAlloc, exp.REWARDS(), "allocations exceed pool");

        // The whale's booked allocation (100e18) exceeds what remains after the
        // re-added small gauge took its (bug-inflated) share.
        assertEq(whaleAlloc, 100 ether, "whale booked its full 100e18");
        assertLt(pool, whaleAlloc, "pool short of the whale's booking");

        // The whale gauge's reward claim reverts -> its rewards are frozen.
        assertTrue(exp.whaleBricked(), "whale gauge reward claim is bricked");
    }
}
