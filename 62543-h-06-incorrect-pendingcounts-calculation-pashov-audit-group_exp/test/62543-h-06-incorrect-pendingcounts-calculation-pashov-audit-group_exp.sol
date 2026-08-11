// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    SpinLottery,
    SpinLotteryFixed,
    MiniToken
} from "./62543-h-06-incorrect-pendingcounts-calculation-pashov-audit-group.sol";

contract IncorrectPendingCountsTest is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    function test_exploit_userControlledPrizeCount_overReservesAndDoSesSpins() public {
        Exploit e = new Exploit();
        e.run();

        // N=3 prizes are physically available.
        assertEq(e.availableN(), 3, "three prizes physically available");

        // A SINGLE attacker spin (which distributes at most 1 prize) reserved all 3
        // by passing a large user-controlled _prizeCount.
        assertEq(e.attackerReserved(), 3, "single attacker spin reserved the whole pool");

        // The bug-induced over-reservation: 3 reserved minus the 1 a spin can distribute.
        assertEq(e.overReservation(), 2, "reserved 2 more prizes than a spin can distribute");

        // The real harm: a legitimate victim's single-prize spin reverts InsufficientPrizes.
        assertTrue(e.victimReverted(), "victim spin reverted");
        assertTrue(e.victimRevertedWithInsufficientPrizes(), "victim reverted with InsufficientPrizes");

        // Marker records the over-reservation magnitude at the SINK.
        MiniToken marker = MiniToken(e.markerAddr());
        assertEq(marker.balanceOf(SINK), 2, "marker records the over-reservation at SINK");

        // Prizes physically remain (3) yet all 3 are reserved by one spin -> DoS.
        SpinLottery lottery = SpinLottery(e.vulnAddr());
        assertEq(lottery.getAvailablePrizes(1), 3, "3 prizes still physically present");
        assertEq(lottery.pendingReserved(1), 3, "yet all 3 are reserved by one spin");
    }

    function test_control_fixedCalculation_victimSpinSucceeds() public {
        // Rebuild the identical scenario against the FIXED contract.
        SpinLotteryFixed lottery = new SpinLotteryFixed();
        lottery.configure(1, 100, 3, 100);

        // The attacker tries the same over-reservation with a large _prizeCount...
        lottery.spin(10, 3);
        // ...but the fixed calc ignores _prizeCount and reserves exactly ONE prize.
        assertEq(lottery.pendingReserved(1), 1, "fixed reserves exactly one prize per spin");

        // A legitimate victim's single-prize spin now SUCCEEDS (no DoS).
        lottery.spin(10, 1);
        assertEq(lottery.pendingReserved(1), 2, "victim's spin reserved its own single prize");
        assertEq(lottery.getAvailablePrizes(1), 3, "prizes remain, spins proceed");
    }
}
