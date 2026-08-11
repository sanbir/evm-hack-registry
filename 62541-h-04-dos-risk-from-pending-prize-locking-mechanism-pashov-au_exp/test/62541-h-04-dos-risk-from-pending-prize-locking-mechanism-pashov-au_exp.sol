// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {Exploit, SpinLottery, SpinLotteryFixed, MiniToken} from
    "./62541-h-04-dos-risk-from-pending-prize-locking-mechanism-pashov-au.sol";

contract PendingPrizeLockingDoSTest is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    uint8 internal constant COMMON = 1;
    uint8 internal constant RARE = 2;

    // ── Exploit-driven harm: UserA locks the scarce prize, UserB is DoS'd ──────
    function test_exploit_pendingLockDoS_locksScarcePrizeAndBlocksNextUser() public {
        Exploit e = new Exploit();
        e.run();

        // The scarce rarity has exactly one prize; the min-guarantee locked it.
        assertEq(e.availableScarcePrizes(), 1, "scarce rarity has 1 prize");
        assertEq(e.lockedScarcePrizes(), 1, "min-guarantee locked the scarce prize");

        // Real harm: the following user's spin reverted (temporary DoS).
        assertTrue(e.userBReverted(), "UserB spin reverted -> DoS");

        // Marker records 1 scarce prize locked out of circulation, at the SINK.
        MiniToken marker = MiniToken(e.markerAddr());
        assertEq(marker.balanceOf(SINK), 1, "marker records 1 locked prize at SINK");
        assertEq(e.sinkMarkerBalance(), 1, "sink marker balance mirror");
    }

    // ── Precise assertion that the DoS reverts with the finding's exact error ──
    function test_exploit_userB_revertsWith_InsufficientPrizes() public {
        SpinLottery lottery = new SpinLottery();
        lottery.configureRarity(COMMON, true, 95, 0.01 ether, 1000);
        lottery.configureRarity(RARE, true, 5, 1 ether, 1);

        // UserA spin: min-guarantee reserves the lone scarce prize.
        lottery.spin(2);
        assertEq(lottery.pendingCountOf(RARE), 1, "scarce prize reserved after UserA");

        // UserB spin: available(1) - pending(1) = 0 < needed(1) -> InsufficientPrizes.
        vm.expectRevert(SpinLottery.InsufficientPrizes.selector);
        lottery.spin(2);
    }

    // ── Negative control: removing the min-guarantee removes the DoS ───────────
    function test_control_fixed_noMinGuarantee_noLockNoDoS() public {
        SpinLotteryFixed lottery = new SpinLotteryFixed();
        lottery.configureRarity(COMMON, true, 95, 0.01 ether, 1000);
        lottery.configureRarity(RARE, true, 5, 1 ether, 1);

        // UserA spin: weighted alloc for the scarce rarity is 0, nothing reserved.
        lottery.spin(2);
        assertEq(lottery.pendingCountOf(RARE), 0, "scarce prize NOT locked in fixed variant");

        // UserB spin succeeds — no DoS.
        lottery.spin(2);
        assertEq(lottery.pendingCountOf(RARE), 0, "still nothing locked; UserB served");
    }
}
